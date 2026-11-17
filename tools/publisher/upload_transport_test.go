package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"cloud.google.com/go/storage"
	"google.golang.org/api/option"
)

// The smallest chunk the SDK accepts; one byte more makes every upload a
// two-chunk resumable session, the path composite parts take.
const fakeGCSChunk = 256 << 10

// fakeGCS is a TLS GCS endpoint that offers HTTP/2 and speaks the resumable
// upload protocol. It holds each first chunk until every stream has sent one,
// so all streams are in flight at once and the connection count shows whether
// they shared a connection.
type fakeGCS struct {
	srv     *httptest.Server
	streams int32

	mu     sync.Mutex
	conns  map[string]bool
	http2  int
	auth   map[string]int
	held   atomic.Int32
	allIn  chan struct{}
	unseen atomic.Int32
}

func newFakeGCS(t *testing.T, streams int) *fakeGCS {
	t.Helper()
	f := &fakeGCS{streams: int32(streams), conns: map[string]bool{}, auth: map[string]int{}, allIn: make(chan struct{})}
	f.srv = httptest.NewUnstartedServer(http.HandlerFunc(f.serve))
	f.srv.EnableHTTP2 = true
	f.srv.StartTLS()
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeGCS) serve(w http.ResponseWriter, r *http.Request) {
	session := strings.HasPrefix(r.URL.Path, "/upload/session/")
	switch {
	case !session && r.URL.Query().Get("uploadType") == "resumable":
		w.Header().Set("Location", fmt.Sprintf("https://%s/upload/session/%s", r.Host, r.URL.Query().Get("name")))
	case session:
		n, _ := io.Copy(io.Discard, r.Body)
		cr := r.Header.Get("Content-Range") // "bytes a-b/*" or "bytes a-b/total"
		f.mu.Lock()
		f.conns[r.RemoteAddr] = true
		if r.ProtoMajor == 2 {
			f.http2++
		}
		f.auth[r.Header.Get("Authorization")]++
		f.mu.Unlock()
		if strings.HasPrefix(cr, "bytes 0-") {
			if f.held.Add(1) == f.streams {
				close(f.allIn)
			}
			select {
			case <-f.allIn:
			case <-time.After(10 * time.Second):
			}
		}
		if strings.HasSuffix(cr, "/*") {
			w.Header().Set("Range", "bytes=0-"+strconv.FormatInt(n-1, 10))
			w.Header().Set("X-Http-Status-Code-Override", "308")
			return
		}
		total := cr[strings.LastIndex(cr, "/")+1:]
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"name":"obj","bucket":"b","size":%q}`, total)
	default:
		f.unseen.Add(1)
		http.Error(w, "unexpected "+r.Method+" "+r.URL.String(), http.StatusBadRequest)
	}
}

// upload runs one two-chunk part upload per stream through the production
// part writer and fails the test on any error.
func (f *fakeGCS) upload(t *testing.T, client *storage.Client) {
	t.Helper()
	c := bucketComposer{bucket: client.Bucket("b")}
	errs := make(chan error, f.streams)
	for i := 0; i < int(f.streams); i++ {
		go func(i int) {
			data := bytes.NewReader(make([]byte, fakeGCSChunk+1))
			errs <- c.uploadPart(context.Background(), fmt.Sprintf("obj.part-%d", i), "application/octet-stream", fakeGCSChunk, data)
		}(i)
	}
	for i := 0; i < int(f.streams); i++ {
		if err := <-errs; err != nil {
			t.Fatalf("upload failed: %v", err)
		}
	}
	if n := f.unseen.Load(); n != 0 {
		t.Fatalf("%d request(s) outside the resumable protocol", n)
	}
}

func (f *fakeGCS) assertOneConnectionPerStream(t *testing.T) {
	t.Helper()
	if len(f.conns) < int(f.streams) {
		t.Errorf("%d concurrent uploads used %d connection(s), want one each", f.streams, len(f.conns))
	}
	if f.http2 != 0 {
		t.Errorf("%d upload request(s) went over HTTP/2", f.http2)
	}
}

func TestUploadTransportGivesEachStreamItsOwnConnection(t *testing.T) {
	f := newFakeGCS(t, 8)

	tr := newUploadTransport(8)
	roots := x509.NewCertPool()
	roots.AddCert(f.srv.Certificate())
	tr.TLSClientConfig = &tls.Config{RootCAs: roots}
	tr.ForceAttemptHTTP2 = true // must not win over Protocols
	client, err := storage.NewClient(context.Background(),
		option.WithHTTPClient(&http.Client{Transport: tr}),
		option.WithEndpoint(f.srv.URL+"/storage/v1/"))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	f.upload(t, client)
	f.assertOneConnectionPerStream(t)
}

// Guards the wiring: the publisher's own client must use the upload transport
// and still authenticate every request.
func TestStorageClientUploadsOnePartPerConnection(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("trusts the fake server through SSL_CERT_FILE, which only Go's Linux root loader honours here")
	}
	f := newFakeGCS(t, 8)
	certFile := filepath.Join(t.TempDir(), "fake-gcs.pem")
	if err := os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: f.srv.Certificate().Raw}), 0o600); err != nil {
		t.Fatal(err)
	}
	// System roots load once per process; no other test in this package uses TLS.
	t.Setenv("SSL_CERT_FILE", certFile)
	t.Setenv("STORAGE_EMULATOR_HOST", f.srv.URL)

	client, err := createStorageClientWithAuth(context.Background(), "test-token", 8)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	f.upload(t, client)
	f.assertOneConnectionPerStream(t)
	if f.auth["Bearer test-token"] == 0 || len(f.auth) != 1 {
		t.Errorf("chunk requests carried Authorization headers %v, want only the access token", f.auth)
	}
}
