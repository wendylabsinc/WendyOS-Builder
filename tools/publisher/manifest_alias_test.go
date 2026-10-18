package main

import (
	"context"
	"encoding/json"
	"fmt"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"reflect"
	"strings"
	"testing"

	"cloud.google.com/go/storage"
	"google.golang.org/api/option"
)

// Exercise alias publication through the real GCS client and metadata routing.
func TestApplyManifestEntryAliases(t *testing.T) {
	for _, pr := range []int{0, 261} {
		t.Run(fmt.Sprint(pr), func(t *testing.T) {
			prefix := prPrefix(pr)
			canonical := deviceManifestPath(prefix, "jetson-agx-orin")
			alias := deviceManifestPath(prefix, "jetson-agx-orin-emmc")
			masterPath := masterManifestPath(prefix)
			master := MasterManifest{}
			masterWrites := 0
			objects := map[string]DeviceManifest{
				canonical: {DeviceID: "jetson-agx-orin", Versions: map[string]VersionMetadata{
					"old":    {IsNightly: true, IsLatest: true},
					"stable": {IsLatest: true},
				}},
				alias: {DeviceID: "jetson-agx-orin-emmc", Versions: map[string]VersionMetadata{
					"v1":  {Path: "stale-bundle", EMMCPath: "stale-bundle", IsNightly: true},
					"old": {Path: "historical-version", IsNightly: true, IsLatest: true},
				}},
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				if r.Method == http.MethodGet {
					name := strings.TrimPrefix(r.URL.Path, "/test-bucket/")
					if name == masterPath {
						w.Header().Set("X-Goog-Generation", "7")
						json.NewEncoder(w).Encode(master)
						return
					}
					obj, ok := objects[name]
					if !ok {
						w.WriteHeader(404)
						return
					}
					w.Header().Set("X-Goog-Generation", "7")
					json.NewEncoder(w).Encode(obj)
					return
				}
				_, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
				if err != nil {
					t.Error(err)
					w.WriteHeader(400)
					return
				}
				parts := multipart.NewReader(r.Body, params["boundary"])
				part, err := parts.NextPart()
				if err != nil {
					t.Error(err)
					w.WriteHeader(400)
					return
				}
				var meta struct {
					Name string `json:"name"`
				}
				if err := json.NewDecoder(part).Decode(&meta); err != nil {
					t.Error(err)
					w.WriteHeader(400)
					return
				}
				if meta.Name != canonical && meta.Name != alias && meta.Name != masterPath {
					t.Errorf("unexpected write %s", meta.Name)
				}
				condition := "0"
				if _, exists := objects[meta.Name]; exists || meta.Name == masterPath {
					condition = "7"
				}
				if got := r.URL.Query().Get("ifGenerationMatch"); got != condition {
					t.Errorf("generation guard = %q, want %s", got, condition)
				}
				part, err = parts.NextPart()
				if err != nil {
					t.Error(err)
					w.WriteHeader(400)
					return
				}
				if meta.Name == masterPath {
					if err := json.NewDecoder(part).Decode(&master); err != nil {
						t.Error(err)
					}
					masterWrites++
					fmt.Fprintf(w, `{"name":%q,"generation":"7"}`, meta.Name)
					return
				}
				var candidate DeviceManifest
				if err := json.NewDecoder(part).Decode(&candidate); err != nil {
					t.Error(err)
					w.WriteHeader(400)
					return
				}
				objects[meta.Name] = candidate
				fmt.Fprintf(w, `{"name":%q,"generation":"7"}`, meta.Name)
			}))
			defer server.Close()
			client, err := storage.NewClient(context.Background(), option.WithEndpoint(server.URL), option.WithoutAuthentication())
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			client.SetRetry(storage.WithPolicy(storage.RetryNever))
			bucket := client.Bucket("test-bucket")
			emmc := ManifestEntry{Device: "jetson-agx-orin", Aliases: []string{"jetson-agx-orin-emmc"}, PR: pr,
				Version: "v1", Nightly: true, Storage: "emmc", FilePath: "new-emmc-bundle", FlashpackPath: "emmc-flashpack",
				Devkit: &DevkitMetadata{Machine: "emmc", KernelVersion: "emmc-kernel", Path: "emmc-devkit"}}
			if err := applyManifestEntry(context.Background(), batchTestLogger(), bucket, emmc); err != nil {
				t.Fatal(err)
			}
			want, got := objects[canonical].Versions["v1"], objects[alias].Versions["v1"]
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("alias differs: %#v / %#v", got, want)
			}
			if got.InstallMode != "recovery" || got.Path != "" || got.EMMCPath != "" || got.EMMCFlashpackPath != "emmc-flashpack" {
				t.Fatalf("unsafe alias metadata: %#v", got)
			}
			if objects[alias].Versions["old"].Path != "historical-version" || !objects[alias].Versions["old"].IsLatest || got.IsLatest || want.IsLatest {
				t.Fatal("staging changed the qualified latest marker")
			}
			nvme := emmc
			nvme.Aliases = nil
			nvme.Storage = "nvme"
			nvme.FilePath = "nvme-rootfs"
			nvme.FlashpackPath = "nvme-flashpack"
			nvme.Devkit = &DevkitMetadata{Machine: "nvme", KernelVersion: "nvme-kernel", Path: "nvme-devkit"}
			if err := applyManifestEntry(context.Background(), batchTestLogger(), bucket, nvme); err != nil {
				t.Fatal(err)
			}
			if objects[alias].Versions["v1"].Devkit.Machine != "emmc" {
				t.Fatal("NVMe publication replaced eMMC alias devkit")
			}
			// An alias-specific driver must survive a subsequent OS publication.
			aliasVersion := objects[alias].Versions["v1"]
			aliasVersion.Extensions = []ExtensionMetadata{{Name: "alias-driver", KernelVersion: "emmc-kernel", Path: "driver.raw"}}
			objects[alias].Versions["v1"] = aliasVersion
			if err := applyManifestEntry(context.Background(), batchTestLogger(), bucket, emmc); err != nil {
				t.Fatal(err)
			}
			got = objects[alias].Versions["v1"]
			if got.Devkit.Machine != "emmc" || len(got.Extensions) != 1 || got.Extensions[0].Name != "alias-driver" {
				t.Fatalf("alias resources lost: %#v", got)
			}
			// Driver publication and image retries must keep the candidate staged.
			driver := ManifestEntry{Device: "jetson-agx-orin-emmc", PR: pr, Version: "v1", Nightly: true,
				Extensions: []ExtensionMetadata{{Name: "second-driver", KernelVersion: "emmc-kernel", Path: "second.raw"}}}
			if err := applyManifestEntry(context.Background(), batchTestLogger(), bucket, driver); err != nil {
				t.Fatal(err)
			}
			if objects[alias].Versions["v1"].IsLatest || !objects[alias].Versions["old"].IsLatest {
				t.Fatal("driver publication promoted an unqualified candidate")
			}
			updates := []MasterManifestUpdate{
				{Device: "jetson-agx-orin", Version: "v1", Nightly: true},
				{Device: "jetson-agx-orin-emmc", Version: "v1", Nightly: true},
			}
			if err := promoteMasterManifestBatch(context.Background(), batchTestLogger(), bucket, prefix, updates, false); err != nil {
				t.Fatal(err)
			}
			for _, path := range []string{canonical, alias} {
				if !objects[path].Versions["v1"].IsLatest || objects[path].Versions["old"].IsLatest {
					t.Fatalf("qualified candidate latest markers incorrect: %s", path)
				}
			}
			if !objects[canonical].Versions["stable"].IsLatest || masterWrites != 1 || master.Devices["jetson-agx-orin-emmc"].LatestNightly != "v1" {
				t.Fatal("promotion changed the stable marker or missed the master update")
			}
			// A partial marker write can be repaired even when the master is current.
			candidate := objects[alias].Versions["v1"]
			candidate.IsLatest = false
			objects[alias].Versions["v1"] = candidate
			if err := applyManifestEntry(context.Background(), batchTestLogger(), bucket, emmc); err != nil {
				t.Fatal(err)
			}
			if objects[alias].Versions["v1"].IsLatest || !objects[canonical].Versions["v1"].IsLatest {
				t.Fatal("staging copied the canonical latest marker onto the alias")
			}
			if err := promoteMasterManifestBatch(context.Background(), batchTestLogger(), bucket, prefix, updates, false); err != nil {
				t.Fatal(err)
			}
			if !objects[alias].Versions["v1"].IsLatest || masterWrites != 1 {
				t.Fatal("no-op master retry failed to repair the latest marker")
			}
			// Staging new bytes for a previously promoted version preserves its marker.
			if err := applyManifestEntry(context.Background(), batchTestLogger(), bucket, emmc); err != nil {
				t.Fatal(err)
			}
			if !objects[canonical].Versions["v1"].IsLatest || !objects[alias].Versions["v1"].IsLatest {
				t.Fatal("staging cleared a previously qualified candidate marker")
			}
			missing := []MasterManifestUpdate{{Device: "jetson-agx-orin", Version: "missing", Nightly: true}}
			if err := promoteMasterManifestBatch(context.Background(), batchTestLogger(), bucket, prefix, missing, false); err == nil || !strings.Contains(err.Error(), "missing version") {
				t.Fatalf("missing metadata promoted: %v", err)
			}
			if masterWrites != 1 {
				t.Fatal("missing candidate advanced the master manifest")
			}
		})
	}
}

func TestManifestEntryRejectsInvalidAliases(t *testing.T) {
	for _, aliases := range [][]string{{"../other"}, {"jetson-agx-orin"}, {"alias", "alias"}, {""}} {
		entry := validEntry()
		entry.Aliases = aliases
		if err := entry.validate(); err == nil {
			t.Errorf("accepted aliases %q", aliases)
		}
	}
}

// A recovery-mode alias must be rejected before --swap uploads an image into
// the legacy path. Run the publisher path in a child because it calls log.Fatal.
func TestSwapRejectsRecoveryAlias(t *testing.T) {
	const childEnv = "TEST_SWAP_RECOVERY_ALIAS_CHILD"
	const endpointEnv = "TEST_SWAP_RECOVERY_ALIAS_ENDPOINT"
	if os.Getenv(childEnv) == "1" {
		client, err := storage.NewClient(context.Background(),
			option.WithEndpoint(os.Getenv(endpointEnv)), option.WithoutAuthentication())
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		swapImageFile(context.Background(), client.Bucket("test-bucket"), "",
			"jetson-agx-orin-emmc", "v1", "nonexistent.img", "", true)
		t.Fatal("swap accepted recovery-mode alias")
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/test-bucket/manifests/jetson-agx-orin-emmc.json" {
			t.Errorf("unexpected GCS request: %s %s", r.Method, r.URL.Path)
			http.Error(w, "unexpected request", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Goog-Generation", "7")
		json.NewEncoder(w).Encode(DeviceManifest{
			DeviceID: "jetson-agx-orin-emmc",
			Versions: map[string]VersionMetadata{"v1": {InstallMode: "recovery", IsNightly: true}},
		})
	}))
	defer server.Close()

	cmd := exec.Command(os.Args[0], "-test.run=^TestSwapRejectsRecoveryAlias$")
	cmd.Env = append(os.Environ(), childEnv+"=1", endpointEnv+"="+server.URL)
	out, err := cmd.CombinedOutput()
	if err == nil || !strings.Contains(string(out), "Cannot use --swap on a recovery-mode release") {
		t.Fatalf("swap did not reject the recovery alias before upload: error=%v, output=%s", err, out)
	}
}
