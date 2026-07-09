package main

import (
	"context"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"cloud.google.com/go/storage"
	"github.com/sirupsen/logrus"
)

// Parallel composite upload.
//
// The GCS Go SDK's default single-stream writer tops out around 10 MB/s to a
// US bucket, so a 7 GB image takes ~11 minutes. Splitting the object into a
// handful of parts, uploading them concurrently and asking GCS to Compose them
// server-side saturates the NIC (~113 MB/s on the CI box's 1 Gbit link) and
// brings the same upload down to ~1 minute. Composite uploads are used only for
// files larger than parallelUploadThreshold; everything smaller keeps the
// original single-stream path.

const (
	// composeMaxParts is the maximum number of source objects a single GCS
	// compose call accepts.
	composeMaxParts = 32
	// minPartSize is the smallest part we will create. Splitting a file into
	// parts smaller than this wastes round-trips without improving throughput.
	minPartSize = 64 << 20 // 64 MiB
	// targetParts is how many parts we aim for on a large file (~16 on a 7 GB
	// image). The count is reduced below this when it would produce parts
	// smaller than minPartSize, and is never allowed to exceed composeMaxParts.
	targetParts = 16
	// partChunkSize is the resumable-upload chunk size for each part writer.
	// The SDK default is 16 MiB, which stalls the stream on serial chunk
	// flushes; 32 MiB keeps the socket busier. This is a per-part in-flight
	// buffer, not the whole part, so memory stays bounded.
	partChunkSize = 32 << 20 // 32 MiB
)

// crc32cTable is the Castagnoli table GCS uses for its CRC32C object checksums.
var crc32cTable = crc32.MakeTable(crc32.Castagnoli)

// Upload limits, initialised from flags in main() before any upload starts.
var (
	// parallelUploadThreshold is the size at or below which the single-stream
	// path is used. Files strictly larger are uploaded as composite parts.
	parallelUploadThreshold int64 = 256 << 20 // 256 MiB
	// uploadSem caps the number of concurrent upload streams across the whole
	// process (composite parts plus whole small files). nil means unlimited,
	// which is only the case in tests that never set it.
	uploadSem chan struct{}
)

// acquireUploadSlot blocks until a slot on the global upload semaphore is free
// or ctx is cancelled. A nil semaphore (tests) never blocks.
func acquireUploadSlot(ctx context.Context, sem chan struct{}) error {
	if sem == nil {
		return ctx.Err()
	}
	select {
	case sem <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// releaseUploadSlot returns a slot to the global upload semaphore.
func releaseUploadSlot(sem chan struct{}) {
	if sem == nil {
		return
	}
	<-sem
}

// partRange is a byte range of the source file that becomes one part object.
type partRange struct {
	offset int64
	length int64
}

// planParts splits a file of the given size into part ranges for a composite
// upload. Files of size <= threshold get a single part (the caller then uses
// the single-stream path). Larger files are split into at most composeMaxParts
// parts, each at least minPartSize (except that the final part carries any
// remainder and is therefore the largest), aiming for targetParts.
func planParts(size, threshold int64) []partRange {
	if size <= 0 {
		return nil
	}
	if size <= threshold {
		return []partRange{{offset: 0, length: size}}
	}

	parts := int64(targetParts)
	// Never make parts smaller than minPartSize: reduce the count until each
	// part clears the floor.
	if size/parts < minPartSize {
		parts = size / minPartSize
		if parts < 1 {
			parts = 1
		}
	}
	if parts > composeMaxParts {
		parts = composeMaxParts
	}

	base := size / parts
	ranges := make([]partRange, 0, parts)
	var off int64
	for i := int64(0); i < parts; i++ {
		n := base
		if i == parts-1 {
			n = size - off // last part takes the remainder
		}
		ranges = append(ranges, partRange{offset: off, length: n})
		off += n
	}
	return ranges
}

// objAttrs is the subset of a composed object's attributes we verify.
type objAttrs struct {
	Size   int64
	CRC32C uint32
}

// gcsComposer is the minimal set of GCS operations the composite upload needs.
// Keeping it behind an interface lets the orchestration be unit-tested without
// a network or a fake GCS server (the module graph has neither).
type gcsComposer interface {
	// uploadPart streams r to a part object named partName with the given
	// content type and resumable chunk size.
	uploadPart(ctx context.Context, partName, contentType string, chunkSize int, r io.Reader) error
	// composeInto composes partNames into dstName, setting contentType on the
	// destination (Compose does not inherit attributes from the sources), and
	// returns the destination object's attributes.
	composeInto(ctx context.Context, dstName, contentType string, partNames []string) (objAttrs, error)
	// deleteObject removes a single object.
	deleteObject(ctx context.Context, name string) error
}

// bucketComposer is the production gcsComposer backed by a real GCS bucket.
type bucketComposer struct {
	bucket *storage.BucketHandle
}

func (b bucketComposer) uploadPart(ctx context.Context, partName, contentType string, chunkSize int, r io.Reader) error {
	obj := b.bucket.Object(partName)
	w := obj.NewWriter(ctx)
	w.ContentType = contentType
	w.ChunkSize = chunkSize
	if _, err := io.Copy(w, r); err != nil {
		w.Close() // best-effort; the write already failed
		return fmt.Errorf("failed to write part to GCS: %w", err)
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("failed to finalize part upload: %w", err)
	}
	return nil
}

func (b bucketComposer) composeInto(ctx context.Context, dstName, contentType string, partNames []string) (objAttrs, error) {
	dst := b.bucket.Object(dstName)
	srcs := make([]*storage.ObjectHandle, len(partNames))
	for i, n := range partNames {
		srcs[i] = b.bucket.Object(n)
	}
	c := dst.ComposerFrom(srcs...)
	// Compose does not carry attributes over from the source parts, so the
	// content type must be set explicitly on the destination.
	c.ContentType = contentType
	attrs, err := c.Run(ctx)
	if err != nil {
		return objAttrs{}, err
	}
	return objAttrs{Size: attrs.Size, CRC32C: attrs.CRC32C}, nil
}

func (b bucketComposer) deleteObject(ctx context.Context, name string) error {
	return b.bucket.Object(name).Delete(ctx)
}

// crc32cCombine returns the CRC32C (Castagnoli) of the concatenation seq1||seq2
// given crc1 = CRC32C(seq1), crc2 = CRC32C(seq2) and len2 = len(seq2). It lets
// the per-part checksums (each computed concurrently over its own byte range)
// be folded, in order, into the whole-file checksum without re-reading the
// file. This is the standard zlib crc32_combine over GF(2), specialised to the
// Castagnoli polynomial.
func crc32cCombine(crc1, crc2 uint32, len2 int64) uint32 {
	if len2 <= 0 {
		return crc1
	}

	var even [32]uint32 // operator for 2^k zero bits, even powers
	var odd [32]uint32  // operator for 2^k zero bits, odd powers

	// odd holds the operator for appending a single zero bit.
	odd[0] = crc32.Castagnoli // the reflected Castagnoli polynomial
	row := uint32(1)
	for n := 1; n < 32; n++ {
		odd[n] = row
		row <<= 1
	}

	gf2MatrixSquare(&even, &odd) // even = operator for 2 zero bits
	gf2MatrixSquare(&odd, &even) // odd  = operator for 4 zero bits

	for {
		gf2MatrixSquare(&even, &odd)
		if len2&1 != 0 {
			crc1 = gf2MatrixTimes(&even, crc1)
		}
		len2 >>= 1
		if len2 == 0 {
			break
		}
		gf2MatrixSquare(&odd, &even)
		if len2&1 != 0 {
			crc1 = gf2MatrixTimes(&odd, crc1)
		}
		len2 >>= 1
		if len2 == 0 {
			break
		}
	}
	return crc1 ^ crc2
}

// gf2MatrixTimes multiplies the GF(2) vector vec by the matrix mat.
func gf2MatrixTimes(mat *[32]uint32, vec uint32) uint32 {
	var sum uint32
	i := 0
	for vec != 0 {
		if vec&1 != 0 {
			sum ^= mat[i]
		}
		vec >>= 1
		i++
	}
	return sum
}

// gf2MatrixSquare sets square = mat * mat over GF(2).
func gf2MatrixSquare(square, mat *[32]uint32) {
	for n := 0; n < 32; n++ {
		square[n] = gf2MatrixTimes(mat, mat[n])
	}
}

// uploadFileComposite uploads srcPath as len(plan) concurrent parts, composes
// them into dstName, verifies the composed object's size and CRC32C against the
// local file, and deletes the part objects. Part objects are named
// "<dstName>.part-<i>". No randomness is used in the names: parts are always
// deleted after a successful compose, and if a part with the same name survives
// a dead prior run it is simply overwritten here — harmless by design. On any
// error the parts that were uploaded are deleted best-effort (failures logged,
// never masking the original error).
func uploadFileComposite(ctx context.Context, c gcsComposer, sem chan struct{}, srcPath, dstName, contentType string, size int64, plan []partRange, chunkSize int) error {
	file, err := os.Open(srcPath)
	if err != nil {
		return fmt.Errorf("failed to open file for composite upload: %w", err)
	}
	defer file.Close()

	partNames := make([]string, len(plan))
	partCRCs := make([]uint32, len(plan))
	errs := make([]error, len(plan))
	for i := range plan {
		partNames[i] = fmt.Sprintf("%s.part-%d", dstName, i)
	}

	var wg sync.WaitGroup
	for i := range plan {
		wg.Add(1)
		go func(i int, pr partRange) {
			defer wg.Done()
			if err := acquireUploadSlot(ctx, sem); err != nil {
				errs[i] = err
				return
			}
			defer releaseUploadSlot(sem)

			// Each part streams from an independent SectionReader, so no whole
			// part is buffered in RAM. The TeeReader feeds the same bytes into
			// a CRC32C hasher so the part's checksum comes for free from the
			// bytes we are already reading.
			section := io.NewSectionReader(file, pr.offset, pr.length)
			h := crc32.New(crc32cTable)
			tee := io.TeeReader(section, h)
			if err := c.uploadPart(ctx, partNames[i], contentType, chunkSize, tee); err != nil {
				errs[i] = fmt.Errorf("part %d: %w", i, err)
				return
			}
			partCRCs[i] = h.Sum32()
		}(i, plan[i])
	}
	wg.Wait()

	// Collect the parts that made it to GCS (for cleanup) and the first error.
	uploaded := make([]string, 0, len(plan))
	var firstErr error
	for i := range plan {
		if errs[i] != nil {
			if firstErr == nil {
				firstErr = errs[i]
			}
			continue
		}
		uploaded = append(uploaded, partNames[i])
	}
	if firstErr != nil {
		cleanupParts(ctx, c, uploaded)
		return firstErr
	}

	attrs, err := c.composeInto(ctx, dstName, contentType, partNames)
	if err != nil {
		cleanupParts(ctx, c, uploaded)
		return fmt.Errorf("compose failed: %w", err)
	}

	// Verify the composed object matches the local file: size first, then the
	// CRC32C folded from the per-part checksums in order.
	if attrs.Size != size {
		cleanupParts(ctx, c, uploaded)
		return fmt.Errorf("composed object size %d does not match local file size %d", attrs.Size, size)
	}
	want := partCRCs[0]
	for i := 1; i < len(plan); i++ {
		want = crc32cCombine(want, partCRCs[i], plan[i].length)
	}
	if attrs.CRC32C != want {
		cleanupParts(ctx, c, uploaded)
		return fmt.Errorf("composed object CRC32C %08x does not match local file CRC32C %08x", attrs.CRC32C, want)
	}

	cleanupParts(ctx, c, uploaded)
	return nil
}

// cleanupParts deletes the given part objects best-effort, logging failures
// without returning them so a caller's original error is never masked.
func cleanupParts(ctx context.Context, c gcsComposer, names []string) {
	for _, n := range names {
		if err := c.deleteObject(ctx, n); err != nil {
			log.WithError(err).WithField("part", n).Warn("Failed to delete composite part object")
		}
	}
}

// contentTypeForPath returns the GCS content type for a local file based on its
// extension, matching (exactly, case-sensitively) the mapping the single-stream
// upload path uses.
func contentTypeForPath(path string) string {
	switch {
	case strings.HasSuffix(path, ".zip"):
		return "application/zip"
	case strings.HasSuffix(path, ".tgz"), strings.HasSuffix(path, ".gz"):
		return "application/gzip"
	case strings.HasSuffix(path, ".xz"):
		return "application/x-xz"
	case strings.HasSuffix(path, ".zst"):
		return "application/zstd"
	default:
		return "application/octet-stream"
	}
}

// sameLocalFile reports whether a and b refer to the same file on disk after
// resolving symlinks (via os.SameFile on the stat results). Both paths must be
// non-empty; an empty path yields false with no error.
func sameLocalFile(a, b string) (bool, error) {
	if a == "" || b == "" {
		return false, nil
	}
	ra, err := filepath.EvalSymlinks(a)
	if err != nil {
		return false, err
	}
	rb, err := filepath.EvalSymlinks(b)
	if err != nil {
		return false, err
	}
	ia, err := os.Stat(ra)
	if err != nil {
		return false, err
	}
	ib, err := os.Stat(rb)
	if err != nil {
		return false, err
	}
	return os.SameFile(ia, ib), nil
}

// logComposePlan logs the chosen part layout for a composite upload.
func logComposePlan(dstName string, size int64, plan []partRange) {
	log.WithFields(logrus.Fields{
		"destination": dstName,
		"size":        size,
		"parts":       len(plan),
	}).Info("Uploading large file as composite parts")
}
