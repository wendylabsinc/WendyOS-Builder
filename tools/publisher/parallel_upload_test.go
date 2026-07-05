package main

import (
	"bytes"
	"context"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// --- Part planning ---------------------------------------------------------

func TestPlanParts(t *testing.T) {
	const threshold = 256 << 20 // matches the default -parallel-upload-threshold

	t.Run("7 GiB yields ~16 parts each >= 64 MiB", func(t *testing.T) {
		size := int64(7) << 30 // 7 GiB
		plan := planParts(size, threshold)
		if len(plan) != 16 {
			t.Errorf("parts = %d, want 16", len(plan))
		}
		assertPlanValid(t, plan, size)
		for i, pr := range plan {
			if pr.length < minPartSize {
				t.Errorf("part %d length %d < minPartSize %d", i, pr.length, minPartSize)
			}
		}
	})

	t.Run("never exceeds 32 parts for any size", func(t *testing.T) {
		for _, size := range []int64{
			int64(300) << 20, // just above threshold
			int64(1) << 30,   // 1 GiB
			int64(7) << 30,   // 7 GiB
			int64(64) << 30,  // 64 GiB
			int64(1) << 40,   // 1 TiB
			int64(1) << 50,   // 1 PiB
		} {
			plan := planParts(size, threshold)
			if len(plan) > composeMaxParts {
				t.Errorf("size %d: parts = %d, want <= %d", size, len(plan), composeMaxParts)
			}
			assertPlanValid(t, plan, size)
			// Every non-final part must clear the 64 MiB floor.
			for i := 0; i < len(plan)-1; i++ {
				if plan[i].length < minPartSize {
					t.Errorf("size %d part %d length %d < minPartSize", size, i, plan[i].length)
				}
			}
		}
	})

	t.Run("single part at or below threshold", func(t *testing.T) {
		for _, size := range []int64{1, 100 << 20, threshold} {
			plan := planParts(size, threshold)
			if len(plan) != 1 {
				t.Errorf("size %d: parts = %d, want 1", size, len(plan))
			}
			if len(plan) == 1 && (plan[0].offset != 0 || plan[0].length != size) {
				t.Errorf("size %d: single part = %+v, want {0,%d}", size, plan[0], size)
			}
		}
	})

	t.Run("just above threshold splits into >=64 MiB parts", func(t *testing.T) {
		size := int64(300) << 20 // 300 MiB
		plan := planParts(size, threshold)
		if len(plan) < 2 {
			t.Fatalf("parts = %d, want >= 2", len(plan))
		}
		assertPlanValid(t, plan, size)
		for i := 0; i < len(plan)-1; i++ {
			if plan[i].length < minPartSize {
				t.Errorf("part %d length %d < minPartSize", i, plan[i].length)
			}
		}
	})

	t.Run("zero size yields no plan", func(t *testing.T) {
		if plan := planParts(0, threshold); plan != nil {
			t.Errorf("planParts(0) = %+v, want nil", plan)
		}
	})
}

// assertPlanValid checks the ranges are contiguous, gap-free, and cover size.
func assertPlanValid(t *testing.T, plan []partRange, size int64) {
	t.Helper()
	var off int64
	for i, pr := range plan {
		if pr.offset != off {
			t.Errorf("part %d offset = %d, want %d (non-contiguous)", i, pr.offset, off)
		}
		if pr.length <= 0 {
			t.Errorf("part %d length = %d, want > 0", i, pr.length)
		}
		off += pr.length
	}
	if off != size {
		t.Errorf("parts cover %d bytes, want %d", off, size)
	}
}

// --- CRC32C incremental combination ---------------------------------------

func TestCRC32CCombine(t *testing.T) {
	data := make([]byte, 4096)
	for i := range data {
		data[i] = byte(i*7 + 3)
	}

	t.Run("two-way fold matches whole checksum", func(t *testing.T) {
		for _, split := range []int{0, 1, 100, 2048, 4095, 4096} {
			a, b := data[:split], data[split:]
			crc1 := crc32.Checksum(a, crc32cTable)
			crc2 := crc32.Checksum(b, crc32cTable)
			got := crc32cCombine(crc1, crc2, int64(len(b)))
			want := crc32.Checksum(data, crc32cTable)
			if got != want {
				t.Errorf("split %d: combined = %08x, want %08x", split, got, want)
			}
		}
	})

	t.Run("three-way sequential fold matches whole checksum", func(t *testing.T) {
		a, b, c := data[:1000], data[1000:3000], data[3000:]
		crcA := crc32.Checksum(a, crc32cTable)
		crcB := crc32.Checksum(b, crc32cTable)
		crcC := crc32.Checksum(c, crc32cTable)
		got := crc32cCombine(crc32cCombine(crcA, crcB, int64(len(b))), crcC, int64(len(c)))
		want := crc32.Checksum(data, crc32cTable)
		if got != want {
			t.Errorf("three-way fold = %08x, want %08x", got, want)
		}
	})

	t.Run("len2 zero is identity", func(t *testing.T) {
		crc1 := crc32.Checksum(data, crc32cTable)
		if got := crc32cCombine(crc1, 0xdeadbeef, 0); got != crc1 {
			t.Errorf("combine with len2=0 = %08x, want %08x", got, crc1)
		}
	})
}

// --- Dedupe decision -------------------------------------------------------

func TestSameLocalFile(t *testing.T) {
	dir := t.TempDir()

	f1 := filepath.Join(dir, "bundle.tegra")
	if err := os.WriteFile(f1, []byte("tegraflash bundle"), 0o644); err != nil {
		t.Fatal(err)
	}
	f2 := filepath.Join(dir, "other.img")
	if err := os.WriteFile(f2, []byte("a different file"), 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "recovery.tegra")
	if err := os.Symlink(f1, link); err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name string
		a, b string
		want bool
	}{
		{"same path", f1, f1, true},
		{"symlink to same file", f1, link, true},
		{"symlink first arg", link, f1, true},
		{"different files", f1, f2, false},
		{"empty a", "", f1, false},
		{"empty b", f1, "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := sameLocalFile(tt.a, tt.b)
			if err != nil {
				t.Fatalf("sameLocalFile() error = %v", err)
			}
			if got != tt.want {
				t.Errorf("sameLocalFile(%q,%q) = %v, want %v", tt.a, tt.b, got, tt.want)
			}
		})
	}
}

// --- Composite upload orchestration (stubbed GCS) --------------------------

// fakeComposer is an in-memory gcsComposer for orchestration tests.
type fakeComposer struct {
	mu           sync.Mutex
	parts        map[string][]byte // partName -> bytes written
	partCT       map[string]string // partName -> content type
	composeCalls []composeCall
	deleted      []string

	failPart    string  // if set, uploadPart of this name returns an error
	overrideCRC *uint32 // if set, composeInto returns this CRC instead of the real one
}

type composeCall struct {
	dst         string
	contentType string
	parts       []string
}

func newFakeComposer() *fakeComposer {
	return &fakeComposer{parts: map[string][]byte{}, partCT: map[string]string{}}
}

func (f *fakeComposer) uploadPart(ctx context.Context, partName, contentType string, chunkSize int, r io.Reader) error {
	// Read the whole part first (streams from the caller's SectionReader/tee),
	// then decide success/failure so the tee CRC is exercised either way.
	buf, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	if partName == f.failPart {
		return fmt.Errorf("simulated upload failure for %s", partName)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.parts[partName] = buf
	f.partCT[partName] = contentType
	return nil
}

func (f *fakeComposer) composeInto(ctx context.Context, dstName, contentType string, partNames []string) (objAttrs, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.composeCalls = append(f.composeCalls, composeCall{dst: dstName, contentType: contentType, parts: append([]string(nil), partNames...)})
	var concat []byte
	for _, n := range partNames {
		concat = append(concat, f.parts[n]...)
	}
	crc := crc32.Checksum(concat, crc32cTable)
	if f.overrideCRC != nil {
		crc = *f.overrideCRC
	}
	return objAttrs{Size: int64(len(concat)), CRC32C: crc}, nil
}

func (f *fakeComposer) deleteObject(ctx context.Context, name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deleted = append(f.deleted, name)
	return nil
}

// writeTempFile writes content to a temp file and returns its path.
func writeTempFile(t *testing.T, content []byte) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "src.bin")
	if err := os.WriteFile(p, content, 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestUploadFileCompositeSuccess(t *testing.T) {
	content := make([]byte, 3000)
	for i := range content {
		content[i] = byte(i % 97)
	}
	src := writeTempFile(t, content)
	dst := "images/dev/ver/image.img.zst"
	ct := "application/zstd"

	// Three unequal parts spanning the whole file.
	plan := []partRange{{0, 1000}, {1000, 1500}, {2500, 500}}
	fc := newFakeComposer()

	if err := uploadFileComposite(context.Background(), fc, nil, src, dst, ct, int64(len(content)), plan, partChunkSize); err != nil {
		t.Fatalf("uploadFileComposite() error = %v", err)
	}

	// Parts uploaded with the right names, byte ranges and content type.
	if len(fc.parts) != 3 {
		t.Fatalf("uploaded %d parts, want 3", len(fc.parts))
	}
	for i, pr := range plan {
		name := fmt.Sprintf("%s.part-%d", dst, i)
		got, ok := fc.parts[name]
		if !ok {
			t.Fatalf("missing part %s", name)
		}
		want := content[pr.offset : pr.offset+pr.length]
		if !bytes.Equal(got, want) {
			t.Errorf("part %d bytes mismatch", i)
		}
		if fc.partCT[name] != ct {
			t.Errorf("part %d content type = %q, want %q", i, fc.partCT[name], ct)
		}
	}

	// Compose called once, with the parts in order and the right destination/CT.
	if len(fc.composeCalls) != 1 {
		t.Fatalf("compose calls = %d, want 1", len(fc.composeCalls))
	}
	cc := fc.composeCalls[0]
	if cc.dst != dst || cc.contentType != ct {
		t.Errorf("compose dst=%q ct=%q, want %q/%q", cc.dst, cc.contentType, dst, ct)
	}
	wantParts := []string{dst + ".part-0", dst + ".part-1", dst + ".part-2"}
	if fmt.Sprint(cc.parts) != fmt.Sprint(wantParts) {
		t.Errorf("compose sources = %v, want %v", cc.parts, wantParts)
	}

	// All parts deleted after success.
	if len(fc.deleted) != 3 {
		t.Errorf("deleted %d parts, want 3 (%v)", len(fc.deleted), fc.deleted)
	}
}

func TestUploadFileCompositeCRCMismatch(t *testing.T) {
	content := []byte("some composite payload that will be split")
	src := writeTempFile(t, content)
	dst := "images/dev/ver/image.img"
	plan := []partRange{{0, 20}, {20, int64(len(content)) - 20}}

	fc := newFakeComposer()
	bad := uint32(0x12345678)
	fc.overrideCRC = &bad

	err := uploadFileComposite(context.Background(), fc, nil, src, dst, "application/octet-stream", int64(len(content)), plan, partChunkSize)
	if err == nil {
		t.Fatal("expected CRC mismatch error, got nil")
	}
	// Parts still cleaned up on the failure path.
	if len(fc.deleted) != 2 {
		t.Errorf("deleted %d parts on CRC mismatch, want 2", len(fc.deleted))
	}
}

func TestUploadFileCompositeSizeMismatch(t *testing.T) {
	content := []byte("payload")
	src := writeTempFile(t, content)
	dst := "images/dev/ver/image.img"
	plan := []partRange{{0, int64(len(content))}}

	fc := newFakeComposer()
	// Claim a larger local size than the parts actually contain.
	err := uploadFileComposite(context.Background(), fc, nil, src, dst, "application/octet-stream", int64(len(content))+100, plan, partChunkSize)
	if err == nil {
		t.Fatal("expected size mismatch error, got nil")
	}
	if len(fc.composeCalls) != 1 {
		t.Errorf("compose should have been attempted once, got %d", len(fc.composeCalls))
	}
}

func TestUploadFileCompositePartFailureCleansUploadedParts(t *testing.T) {
	content := make([]byte, 300)
	src := writeTempFile(t, content)
	dst := "images/dev/ver/image.img"
	plan := []partRange{{0, 100}, {100, 100}, {200, 100}}

	fc := newFakeComposer()
	fc.failPart = dst + ".part-1"

	err := uploadFileComposite(context.Background(), fc, nil, src, dst, "application/octet-stream", int64(len(content)), plan, partChunkSize)
	if err == nil {
		t.Fatal("expected part upload error, got nil")
	}
	// Compose must not run when a part failed.
	if len(fc.composeCalls) != 0 {
		t.Errorf("compose calls = %d, want 0 after part failure", len(fc.composeCalls))
	}
	// Only the two parts that uploaded successfully are cleaned up; the failed
	// part was never committed.
	for _, n := range fc.deleted {
		if n == dst+".part-1" {
			t.Errorf("deleted the failed part %s; only successfully uploaded parts should be cleaned up", n)
		}
	}
	if len(fc.deleted) != 2 {
		t.Errorf("deleted %d parts, want 2 (%v)", len(fc.deleted), fc.deleted)
	}
}
