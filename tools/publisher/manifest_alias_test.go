package main

import (
	"context"
	"encoding/json"
	"fmt"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
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
			objects := map[string]DeviceManifest{
				alias: {DeviceID: "jetson-agx-orin-emmc", Versions: map[string]VersionMetadata{
					"v1":  {Path: "stale-bundle", EMMCPath: "stale-bundle", IsNightly: true},
					"old": {Path: "historical-version", IsNightly: true, IsLatest: true},
				}},
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				if r.Method == http.MethodGet {
					name := strings.TrimPrefix(r.URL.Path, "/test-bucket/")
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
				if meta.Name != canonical && meta.Name != alias {
					t.Errorf("unexpected write %s", meta.Name)
				}
				condition := "0"
				if _, exists := objects[meta.Name]; exists {
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
			if objects[alias].Versions["old"].Path != "historical-version" || objects[alias].Versions["old"].IsLatest {
				t.Fatal("historical version lost or still latest")
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
