package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"cloud.google.com/go/storage"
	"github.com/sirupsen/logrus"
	"google.golang.org/api/googleapi"
	"google.golang.org/api/option"
)

// Exercise the real storage reader/writer, including failures on upload commit.
type manifestTestServer struct {
	manifest                MasterManifest
	reads, writes           int
	generation              int
	readStatus, writeStatus []int
	conditions              []string
	names                   []string
	concurrentDevice        bool
	malformed               bool
}

func (s *manifestTestServer) bucket(t *testing.T) *storage.BucketHandle {
	t.Helper()
	s.generation = 7
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet {
			s.reads++
			if len(s.readStatus) > 0 {
				code := s.readStatus[0]
				s.readStatus = s.readStatus[1:]
				if code != 200 {
					w.WriteHeader(code)
					fmt.Fprintf(w, `{"error":{"code":%d,"message":"test read failure"}}`, code)
					return
				}
			}
			w.Header().Set("X-Goog-Generation", fmt.Sprint(s.generation))
			if s.malformed {
				fmt.Fprint(w, "broken JSON")
			} else {
				json.NewEncoder(w).Encode(s.manifest)
			}
			return
		}
		if r.Method != http.MethodPost {
			t.Errorf("unexpected request %s %s", r.Method, r.URL)
			w.WriteHeader(500)
			return
		}
		s.writes++
		s.conditions = append(s.conditions, r.URL.Query().Get("ifGenerationMatch"))
		_, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if err != nil {
			t.Error(err)
			w.WriteHeader(500)
			return
		}
		reader := multipart.NewReader(r.Body, params["boundary"])
		metadataPart, err := reader.NextPart()
		if err != nil {
			t.Error(err)
			w.WriteHeader(500)
			return
		}
		var metadata struct {
			Name         string `json:"name"`
			CacheControl string `json:"cacheControl"`
		}
		if err := json.NewDecoder(metadataPart).Decode(&metadata); err != nil {
			t.Error(err)
			w.WriteHeader(500)
			return
		}
		if metadata.CacheControl != manifestCacheControl {
			t.Errorf("cache control = %q", metadata.CacheControl)
		}
		s.names = append(s.names, metadata.Name)
		dataPart, err := reader.NextPart()
		if err != nil {
			t.Error(err)
			w.WriteHeader(500)
			return
		}
		var candidate MasterManifest
		if err := json.NewDecoder(dataPart).Decode(&candidate); err != nil {
			t.Error(err)
			w.WriteHeader(500)
			return
		}
		if len(s.writeStatus) > 0 {
			code := s.writeStatus[0]
			s.writeStatus = s.writeStatus[1:]
			if code != 200 {
				if s.concurrentDevice {
					s.manifest.Devices["concurrent"] = DeviceLatestInfo{Latest: "other-release"}
					s.generation++
				}
				w.WriteHeader(code)
				fmt.Fprintf(w, `{"error":{"code":%d,"message":"test write failure"}}`, code)
				return
			}
		}
		s.manifest = candidate
		s.generation++
		fmt.Fprintf(w, `{"name":%q,"generation":%q}`, metadata.Name, fmt.Sprint(s.generation))
	}))
	t.Cleanup(server.Close)
	client, err := storage.NewClient(context.Background(), option.WithEndpoint(server.URL), option.WithoutAuthentication())
	if err != nil {
		t.Fatal(err)
	}
	// Test the publisher's transaction retry, rather than the SDK's HTTP retry.
	client.SetRetry(storage.WithPolicy(storage.RetryNever))
	t.Cleanup(func() { client.Close() })
	return client.Bucket("test-bucket")
}

func batchTestLogger() *logrus.Entry {
	l := logrus.New()
	l.SetOutput(io.Discard)
	return logrus.NewEntry(l)
}

func TestMasterManifestBatchSingleWrite(t *testing.T) {
	for _, prefix := range []string{"", "pr/270/"} {
		t.Run(prefix, func(t *testing.T) {
			untouched := DeviceLatestInfo{Latest: "old", LatestNightly: "old-nightly", Stability: "experimental"}
			s := &manifestTestServer{manifest: MasterManifest{
				LastUpdated: time.Unix(1, 0),
				Devices:     map[string]DeviceLatestInfo{"untouched": untouched, "device-0": {Latest: "stable-old"}, "device-1": {LatestNightly: "nightly-old"}},
				Firmware:    map[string]DeviceLatestInfo{"esp32": {Latest: "firmware-old"}},
			}}
			var updates []MasterManifestUpdate
			for i := 0; i < 10; i++ {
				updates = append(updates, MasterManifestUpdate{Device: fmt.Sprintf("device-%d", i), Version: "new", Nightly: i%2 == 0, Stability: "experimental"})
			}
			updates = append(updates, updates[0]) // A second storage variant.
			if err := updateMasterManifestBatch(context.Background(), batchTestLogger(), s.bucket(t), prefix, updates, true); err != nil {
				t.Fatal(err)
			}
			if s.reads != 1 || s.writes != 1 {
				t.Fatalf("reads/writes = %d/%d, want 1/1", s.reads, s.writes)
			}
			if s.names[0] != prefix+"manifests/master.json" || s.conditions[0] != "7" {
				t.Fatalf("name/condition = %v/%v", s.names, s.conditions)
			}
			if s.manifest.Devices["untouched"] != untouched || s.manifest.Firmware["esp32"].Latest != "firmware-old" {
				t.Fatal("unrelated entries changed")
			}
			if s.manifest.Devices["device-0"].Latest != "stable-old" || s.manifest.Devices["device-1"].LatestNightly != "nightly-old" {
				t.Fatal("opposite channel changed")
			}
			for _, u := range updates {
				got := s.manifest.Devices[u.Device]
				version := got.Latest
				if u.Nightly {
					version = got.LatestNightly
				}
				if version != u.Version || got.Stability != u.Stability || got.ManifestPath != prefix+"manifests/"+u.Device+".json" {
					t.Errorf("%s = %+v", u.Device, got)
				}
			}
			if !s.manifest.LastUpdated.After(time.Unix(1, 0)) {
				t.Fatal("timestamp not refreshed")
			}
		})
	}
}

func TestMasterManifestBatchRetries(t *testing.T) {
	for _, code := range []int{412, 429, 503} {
		t.Run(fmt.Sprint(code), func(t *testing.T) {
			s := &manifestTestServer{manifest: MasterManifest{Devices: map[string]DeviceLatestInfo{}}, writeStatus: []int{code}, concurrentDevice: true}
			err := updateMasterManifestBatch(context.Background(), batchTestLogger(), s.bucket(t), "", []MasterManifestUpdate{{Device: "iq", Version: "new"}}, true)
			if err != nil {
				t.Fatal(err)
			}
			if s.reads != 2 || s.writes != 2 || !reflect.DeepEqual(s.conditions, []string{"7", "8"}) {
				t.Fatalf("reads/writes/conditions = %d/%d/%v", s.reads, s.writes, s.conditions)
			}
			if s.manifest.Devices["concurrent"].Latest != "other-release" || s.manifest.Devices["iq"].Latest != "new" {
				t.Fatal("retry lost an update")
			}
		})
	}
}

func TestMasterManifestBatchReadFailures(t *testing.T) {
	for _, code := range []int{403, 404, 429} {
		t.Run(fmt.Sprint(code), func(t *testing.T) {
			s := &manifestTestServer{readStatus: []int{code}}
			err := updateMasterManifestBatch(context.Background(), batchTestLogger(), s.bucket(t), "", []MasterManifestUpdate{{Device: "iq", Version: "new"}}, true)
			if code == 403 {
				if err == nil || s.writes != 0 {
					t.Fatalf("read failure: err=%v writes=%d", err, s.writes)
				}
			} else {
				if err != nil || s.writes != 1 {
					t.Fatalf("err=%v writes=%d", err, s.writes)
				}
				if code == 404 && s.conditions[0] != "0" {
					t.Fatalf("create condition = %v", s.conditions)
				}
				if code == 429 && s.reads != 2 {
					t.Fatalf("reads=%d", s.reads)
				}
			}
		})
	}
	s := &manifestTestServer{malformed: true}
	if err := updateMasterManifestBatch(context.Background(), batchTestLogger(), s.bucket(t), "", []MasterManifestUpdate{{Device: "iq", Version: "new"}}, true); err == nil || s.writes != 0 {
		t.Fatalf("malformed read: err=%v writes=%d", err, s.writes)
	}
}

func TestMasterManifestBatchValidation(t *testing.T) {
	for _, input := range []string{`null`, `{}`, `[] []`, `[{"device":"iq","version":"new","nighty":true}]`, `[{"device":"../bad","version":"new"}]`, `[{"device":"iq"}]`, `[{"device":"iq","version":"new","stability":"bad"}]`, `[{"device":"iq","version":"new"},{"device":"iq","version":"other"}]`, `[{"device":"iq","version":"new","nightly":true},{"device":"iq","version":"new"}]`} {
		t.Run(input, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "batch.json")
			os.WriteFile(path, []byte(input), 0600)
			if _, err := readMasterManifestBatch(path); err == nil {
				t.Fatal("invalid batch accepted")
			}
		})
	}
	// An invalid later entry must fail before reading or writing any object.
	if err := updateMasterManifestBatch(context.Background(), batchTestLogger(), nil, "", []MasterManifestUpdate{{Device: "iq", Version: "new"}, {Device: "bad"}}, true); err == nil {
		t.Fatal("invalid batch accepted")
	}
	if err := updateMasterManifestBatch(context.Background(), batchTestLogger(), nil, "", nil, true); err != nil {
		t.Fatal(err)
	}
}

func TestMasterManifestBatchPermanentWriteFailure(t *testing.T) {
	s := &manifestTestServer{manifest: MasterManifest{Devices: map[string]DeviceLatestInfo{
		"iq": {Latest: "old"},
	}}, writeStatus: []int{403}}
	err := updateMasterManifestBatch(context.Background(), batchTestLogger(), s.bucket(t), "",
		[]MasterManifestUpdate{{Device: "iq", Version: "new"}}, true)
	var apiErr *googleapi.Error
	if !errors.As(err, &apiErr) || apiErr.Code != 403 || s.writes != 1 {
		t.Fatalf("err=%v writes=%d", err, s.writes)
	}
	if s.manifest.Devices["iq"].Latest != "old" {
		t.Fatal("failed write changed the published pointer")
	}
}

func TestMasterManifestRetryStops(t *testing.T) {
	for _, code := range []int{403, 429, 412} {
		err := &googleapi.Error{Code: code}
		if got := retryMasterManifest(context.Background(), batchTestLogger(), err, 10, 10); got != err {
			t.Errorf("code %d: got %v", code, got)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := retryMasterManifest(ctx, batchTestLogger(), &googleapi.Error{Code: 429}, 1, 10); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation: %v", err)
	}
}

func TestMasterManifestSingleDeviceCompatibility(t *testing.T) {
	for _, force := range []bool{false, true} {
		s := &manifestTestServer{manifest: MasterManifest{LastUpdated: time.Unix(1, 0), Devices: map[string]DeviceLatestInfo{"iq": {Latest: "same", ManifestPath: "manifests/iq.json", Stability: "stable"}}}}
		if err := updateMasterManifest(context.Background(), batchTestLogger(), s.bucket(t), "", "iq", "same", false, "", force); err != nil {
			t.Fatal(err)
		}
		if (s.writes == 1) != force {
			t.Fatalf("force=%v writes=%d", force, s.writes)
		}
	}
}
