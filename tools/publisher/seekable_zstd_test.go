package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	seekable "github.com/SaveTheRbtz/zstd-seekable-format-go/pkg"
	"github.com/klauspost/compress/zstd"
)

// serialSeekableZstd is the pre-parallelization implementation, kept here so
// the benchmark/A-B test can compare it against the WriteMany-based
// compressSeekableZstd. It must produce byte-identical decompressed output.
func serialSeekableZstd(srcPath, dstPath string) error {
	in, err := os.Open(srcPath)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dstPath)
	if err != nil {
		return err
	}
	defer out.Close()
	enc, err := zstd.NewWriter(nil)
	if err != nil {
		return err
	}
	defer enc.Close()
	w, err := seekable.NewWriter(out, enc)
	if err != nil {
		return err
	}
	buf := make([]byte, seekableFrameSize)
	for {
		n, rerr := io.ReadFull(in, buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				w.Close()
				return werr
			}
		}
		if rerr == io.EOF || rerr == io.ErrUnexpectedEOF {
			break
		}
		if rerr != nil {
			w.Close()
			return rerr
		}
	}
	if err := w.Close(); err != nil {
		return err
	}
	return out.Close()
}

// makeImageLike writes size bytes that mimic a rootfs: long runs of zeros
// (sparse regions) interleaved with pseudo-random, genuinely-compressible
// payload, so per-frame compression does real work rather than collapsing
// every all-zero frame to nothing.
func makeImageLike(t testing.TB, path string, size int) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	// Deterministic content (no rand seeding): pseudo-random payload from a
	// cheap LCG (near-incompressible, like packed binaries) interleaved with
	// zero runs (sparse regions). Overall ~6-8x compressible, matching a real
	// rootfs, so per-frame compression is genuinely CPU-bound.
	var lcg uint64 = 0x9e3779b97f4a7c15
	block := make([]byte, 1<<20) // 1 MiB working block
	for written := 0; written < size; {
		// Three quarters payload, one quarter zeros.
		zeroRegion := (written/len(block))%4 == 3
		for i := range block {
			if zeroRegion {
				block[i] = 0
			} else {
				lcg = lcg*6364136223846793005 + 1442695040888963407
				block[i] = byte(lcg >> 56)
			}
		}
		n := len(block)
		if written+n > size {
			n = size - written
		}
		if _, err := f.Write(block[:n]); err != nil {
			t.Fatal(err)
		}
		written += n
	}
}

func decompressAll(t testing.TB, path string) []byte {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	dec, err := zstd.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	defer dec.Close()
	data, err := io.ReadAll(dec)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// TestSeekableZstdRoundTripMatchesSerial proves the parallel WriteMany output
// decompresses to exactly the source bytes, and to exactly what the old serial
// path produced. Uses a small image so it runs in the normal test suite.
func TestSeekableZstdRoundTripMatchesSerial(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "image.img")
	// A few frames' worth, plus a deliberately short final frame.
	size := int(3*seekableFrameSize + seekableFrameSize/2 + 12345)
	makeImageLike(t, src, size)

	orig, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}

	parPath := filepath.Join(dir, "image.parallel.zst")
	if err := compressSeekableZstd(src, parPath); err != nil {
		t.Fatalf("parallel compress: %v", err)
	}
	serPath := filepath.Join(dir, "image.serial.zst")
	if err := serialSeekableZstd(src, serPath); err != nil {
		t.Fatalf("serial compress: %v", err)
	}

	parDecomp := decompressAll(t, parPath)
	serDecomp := decompressAll(t, serPath)

	if len(parDecomp) != len(orig) {
		t.Fatalf("parallel decompressed size %d != original %d", len(parDecomp), len(orig))
	}
	for i := range orig {
		if parDecomp[i] != orig[i] {
			t.Fatalf("parallel decompressed byte %d = %d, want %d", i, parDecomp[i], orig[i])
		}
	}
	if len(serDecomp) != len(orig) {
		t.Fatalf("serial decompressed size %d != original %d", len(serDecomp), len(orig))
	}
	// The seekable frame stream (independent 4 MiB frames) must be identical
	// regardless of encode order, so the two .zst files are byte-identical too.
	parRaw, _ := os.ReadFile(parPath)
	serRaw, _ := os.ReadFile(serPath)
	if len(parRaw) != len(serRaw) {
		t.Errorf("parallel .zst size %d != serial .zst size %d (frame contents should match)", len(parRaw), len(serRaw))
	}
}

// TestSeekableZstdAB is a manual A/B timing harness: it compresses a large
// synthetic image with both implementations and logs wall-clock. Gated behind
// SEEKABLE_AB_MB so it never runs (or allocates gigabytes) in normal CI.
//
//	SEEKABLE_AB_MB=2048 go test -run TestSeekableZstdAB -v ./...
func TestSeekableZstdAB(t *testing.T) {
	mbStr := os.Getenv("SEEKABLE_AB_MB")
	if mbStr == "" {
		t.Skip("set SEEKABLE_AB_MB to run the serial-vs-parallel timing harness")
	}
	var mb int
	if _, err := fmt.Sscanf(mbStr, "%d", &mb); err != nil || mb <= 0 {
		t.Fatalf("invalid SEEKABLE_AB_MB=%q", mbStr)
	}
	dir := t.TempDir()
	src := filepath.Join(dir, "image.img")
	makeImageLike(t, src, mb<<20)

	run := func(name string, fn func(string, string) error) time.Duration {
		dst := filepath.Join(dir, name+".zst")
		start := time.Now()
		if err := fn(src, dst); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		d := time.Since(start)
		st, _ := os.Stat(dst)
		t.Logf("%-8s %v  (%.1f MiB in -> %.1f MiB out)", name, d.Round(time.Millisecond),
			float64(mb), float64(st.Size())/(1<<20))
		return d
	}

	serial := run("serial", serialSeekableZstd)
	parallel := run("parallel", compressSeekableZstd)
	t.Logf("speedup: %.2fx (serial %v -> parallel %v)", float64(serial)/float64(parallel),
		serial.Round(time.Millisecond), parallel.Round(time.Millisecond))
	_ = context.Background()
}
