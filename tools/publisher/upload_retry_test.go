package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"cloud.google.com/go/storage"
	"google.golang.org/api/option"
)

// Ways the first attempt of a request fails, as GCS did in CI.
const (
	failReset = "reset" // TCP RST: "connection reset by peer"
	failEOF   = "eof"   // connection closed without a response: bare EOF
	fail503   = "503"
	fail403   = "403" // not transient: must not be retried
)

// flakyGCS fails the first attempt of each configured request, then answers.
// Keys of fail are "start:<object>", "compose:<object>" and "multipart".
type flakyGCS struct {
	srv  *httptest.Server
	fail map[string]string

	mu       sync.Mutex
	attempts map[string]int
	body     map[string][]byte // last successful multipart body
}

func newFlakyGCS(t *testing.T, fail map[string]string) (*flakyGCS, *storage.Client) {
	t.Helper()
	f := &flakyGCS{fail: fail, attempts: map[string]int{}, body: map[string][]byte{}}
	f.srv = httptest.NewTLSServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)

	tr := newUploadTransport(4)
	roots := x509.NewCertPool()
	roots.AddCert(f.srv.Certificate())
	tr.TLSClientConfig = &tls.Config{RootCAs: roots}
	client, err := storage.NewClient(context.Background(),
		option.WithHTTPClient(&http.Client{Transport: tr}),
		option.WithEndpoint(f.srv.URL+"/storage/v1/"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close() })
	return f, client
}

// failFirst records an attempt for key and, on the first one, fails the
// request as configured. It reports whether the request was failed.
func (f *flakyGCS) failFirst(w http.ResponseWriter, r *http.Request, key string) bool {
	body, _ := io.ReadAll(r.Body)
	f.mu.Lock()
	f.attempts[key]++
	first := f.attempts[key] == 1
	if !first || f.fail[key] == "" {
		f.body[key] = body
	}
	f.mu.Unlock()
	if !first {
		return false
	}
	switch f.fail[key] {
	case failReset, failEOF:
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			panic(err)
		}
		if f.fail[key] == failReset {
			// Skip the TLS close_notify, which the client would read as EOF.
			tcp := conn.(*tls.Conn).NetConn().(*net.TCPConn)
			tcp.SetLinger(0)
			tcp.Close()
		} else {
			conn.Close()
		}
	case fail503:
		http.Error(w, "Service Unavailable", http.StatusServiceUnavailable)
	case fail403:
		http.Error(w, "Forbidden", http.StatusForbidden)
	default:
		return false
	}
	return true
}

func (f *flakyGCS) serve(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	switch {
	case strings.HasPrefix(r.URL.Path, "/upload/session/"):
		n, _ := io.Copy(io.Discard, r.Body)
		cr := r.Header.Get("Content-Range") // "bytes a-b/*" or "bytes a-b/total"
		if strings.HasSuffix(cr, "/*") {
			w.Header().Set("Range", "bytes=0-"+strconv.FormatInt(n-1, 10))
			w.Header().Set("X-Http-Status-Code-Override", "308")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"name":"obj","bucket":"b","size":%q}`, cr[strings.LastIndex(cr, "/")+1:])
	case q.Get("uploadType") == "resumable":
		name := q.Get("name")
		if f.failFirst(w, r, "start:"+name) {
			return
		}
		w.Header().Set("Location", fmt.Sprintf("https://%s/upload/session/%s", r.Host, url.PathEscape(name)))
	case q.Get("uploadType") == "multipart":
		if f.failFirst(w, r, "multipart") {
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"name":"obj","bucket":"b"}`)
	case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/compose"):
		name, _ := url.PathUnescape(strings.TrimSuffix(r.URL.EscapedPath()[strings.Index(r.URL.EscapedPath(), "/o/")+3:], "/compose"))
		if f.failFirst(w, r, "compose:"+name) {
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"name":%q,"bucket":"b","size":"7","crc32c":"AAAAAA=="}`, name)
	case r.Method == http.MethodGet:
		http.Error(w, `{"error":{"code":404,"message":"Not Found"}}`, http.StatusNotFound)
	default:
		http.Error(w, "unexpected "+r.Method+" "+r.URL.String(), http.StatusBadRequest)
	}
}

func (f *flakyGCS) attemptsFor(key string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.attempts[key]
}

// partPayload is one byte over a chunk, so the part takes the resumable
// session path that production parts take.
func partPayload() io.Reader { return bytes.NewReader(make([]byte, fakeGCSChunk+1)) }

func TestUploadPartRetriesTransientSessionStart(t *testing.T) {
	for _, mode := range []string{failReset, fail503} {
		t.Run(mode, func(t *testing.T) {
			f, client := newFlakyGCS(t, map[string]string{"start:img.part-0": mode})
			c := bucketComposer{bucket: client.Bucket("b")}
			if err := c.uploadPart(context.Background(), "img.part-0", "application/zstd", fakeGCSChunk, partPayload()); err != nil {
				t.Fatalf("upload failed after a transient %s on session start: %v", mode, err)
			}
			if n := f.attemptsFor("start:img.part-0"); n != 2 {
				t.Errorf("session start attempts = %d, want 2", n)
			}
		})
	}
}

func TestUploadPartDoesNotRetryPermanentError(t *testing.T) {
	f, client := newFlakyGCS(t, map[string]string{"start:img.part-0": fail403})
	c := bucketComposer{bucket: client.Bucket("b")}
	if err := c.uploadPart(context.Background(), "img.part-0", "application/zstd", fakeGCSChunk, partPayload()); err == nil {
		t.Fatal("upload succeeded, want the 403 returned")
	}
	if n := f.attemptsFor("start:img.part-0"); n != 1 {
		t.Errorf("session start attempts = %d, want 1 (403 is not transient)", n)
	}
}

func TestComposeRetriesBareEOF(t *testing.T) {
	f, client := newFlakyGCS(t, map[string]string{"compose:img.zst": failEOF})
	c := bucketComposer{bucket: client.Bucket("b")}
	attrs, err := c.composeInto(context.Background(), "img.zst", "application/zstd", []string{"img.zst.part-0", "img.zst.part-1"})
	if err != nil {
		t.Fatalf("compose failed after a bare EOF: %v", err)
	}
	if attrs.Size != 7 {
		t.Errorf("composed size = %d, want 7", attrs.Size)
	}
	if n := f.attemptsFor("compose:img.zst"); n != 2 {
		t.Errorf("compose attempts = %d, want 2", n)
	}
}

func TestUploadFileRetriesSmallFile(t *testing.T) {
	f, client := newFlakyGCS(t, map[string]string{"multipart": fail503})
	payload := []byte("small-file-payload")
	local := filepath.Join(t.TempDir(), "img.bmap")
	if err := os.WriteFile(local, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := uploadFile(context.Background(), client.Bucket("b"), "", local, "dev", "v1"); err != nil {
		t.Fatalf("small-file upload failed after a transient 503: %v", err)
	}
	if n := f.attemptsFor("multipart"); n != 2 {
		t.Errorf("multipart attempts = %d, want 2", n)
	}
	// The retry must resend the whole body, not an already-drained reader.
	f.mu.Lock()
	defer f.mu.Unlock()
	if !bytes.Contains(f.body["multipart"], payload) {
		t.Errorf("retried request did not carry the file contents")
	}
}
