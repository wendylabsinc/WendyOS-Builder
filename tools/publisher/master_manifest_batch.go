package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"os"
	"time"

	"cloud.google.com/go/storage"
	"github.com/sirupsen/logrus"
	"google.golang.org/api/googleapi"
)

// MasterManifestUpdate changes one device's pointer in one channel. The caller
// selects eligible devices after publishing their manifests and checking drivers.
// The invocation's --pr flag selects the namespace for the entire batch.
type MasterManifestUpdate struct {
	Device    string `json:"device"`
	Version   string `json:"version"`
	Nightly   bool   `json:"nightly"`
	Stability string `json:"stability,omitempty"`
}

func readMasterManifestBatch(path string) ([]MasterManifestUpdate, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var updates []MasterManifestUpdate
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&updates); err != nil {
		return nil, fmt.Errorf("parsing master manifest batch: %w", err)
	}
	if updates == nil {
		return nil, fmt.Errorf("master manifest batch must be a JSON array")
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return nil, fmt.Errorf("unexpected data after master manifest batch")
	}
	return normalizeMasterManifestBatch(updates)
}

func normalizeMasterManifestBatch(updates []MasterManifestUpdate) ([]MasterManifestUpdate, error) {
	seen := make(map[string]MasterManifestUpdate)
	result := make([]MasterManifestUpdate, 0, len(updates))
	for _, update := range updates {
		if err := validateDeviceType(update.Device); err != nil {
			return nil, err
		}
		if err := validateVersion(update.Version); err != nil {
			return nil, fmt.Errorf("%s: %w", update.Device, err)
		}
		if update.Stability == "" {
			update.Stability = "stable"
		}
		if err := validateStability(update.Stability); err != nil {
			return nil, fmt.Errorf("%s: %w", update.Device, err)
		}
		if previous, exists := seen[update.Device]; exists {
			if previous != update {
				return nil, fmt.Errorf("conflicting master manifest updates for %s", update.Device)
			}
			continue // Storage variants share a device pointer.
		}
		seen[update.Device] = update
		result = append(result, update)
	}
	return result, nil
}

func updateMasterManifestBatch(ctx context.Context, logger *logrus.Entry, bucket *storage.BucketHandle, prefix string, updates []MasterManifestUpdate, forceWrite bool) error {
	updates, err := normalizeMasterManifestBatch(updates)
	if err != nil || len(updates) == 0 {
		return err
	}
	path := masterManifestPath(prefix)
	logger = logger.WithFields(logrus.Fields{"manifest_path": path, "device_count": len(updates)})
	// Retry the complete read/modify/write transaction here rather than letting
	// the SDK retry a stale upload indefinitely after a rate limit or conflict.
	obj := bucket.Object(path).Retryer(storage.WithPolicy(storage.RetryNever))
	const maxAttempts = 10
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		var manifest MasterManifest
		var generation int64
		r, err := obj.NewReader(ctx)
		switch {
		case err == nil:
			content, readErr := io.ReadAll(io.LimitReader(r, 10*1024*1024+1))
			generation = r.Attrs.Generation
			r.Close()
			if readErr != nil {
				if err := retryMasterManifest(ctx, logger, readErr, attempt, maxAttempts); err != nil {
					return fmt.Errorf("read master manifest: %w", err)
				}
				continue
			}
			if len(content) > 10*1024*1024 {
				return fmt.Errorf("master manifest exceeds 10 MiB")
			}
			if err := json.Unmarshal(content, &manifest); err != nil {
				return fmt.Errorf("decode master manifest: %w", err)
			}
		case errors.Is(err, storage.ErrObjectNotExist):
			// Only a missing object permits creation; never overwrite on a read error.
		default:
			if err := retryMasterManifest(ctx, logger, err, attempt, maxAttempts); err != nil {
				return fmt.Errorf("read master manifest: %w", err)
			}
			continue
		}
		if manifest.Devices == nil {
			manifest.Devices = make(map[string]DeviceLatestInfo)
		}
		changed := false
		for _, update := range updates {
			info := manifest.Devices[update.Device]
			previous := info
			info.ManifestPath = deviceManifestPath(prefix, update.Device)
			info.Stability = update.Stability
			if update.Nightly {
				info.LatestNightly = update.Version
			} else {
				info.Latest = update.Version
			}
			changed = changed || info != previous
			manifest.Devices[update.Device] = info
		}
		if !changed && !forceWrite {
			return nil
		}
		// Publishing an existing version still refreshes last_updated. forceWrite
		// does not bypass the generation check: retries must preserve other writers.
		manifest.LastUpdated = time.Now()
		content, err := json.MarshalIndent(manifest, "", "  ")
		if err != nil {
			return err
		}
		conditions := storage.Conditions{GenerationMatch: generation}
		if generation == 0 {
			conditions = storage.Conditions{DoesNotExist: true}
		}
		w := obj.If(conditions).NewWriter(ctx)
		w.CacheControl = manifestCacheControl
		if _, err = w.Write(content); err != nil {
			w.Close()
		} else {
			err = w.Close() // GCS commits the upload here, including rate-limit errors.
		}
		if err == nil {
			logger.Info("Published master manifest batch")
			return nil
		}
		if err := retryMasterManifest(ctx, logger, err, attempt, maxAttempts); err != nil {
			return fmt.Errorf("write master manifest: %w", err)
		}
	}
	return fmt.Errorf("master manifest retry limit reached")
}

// A retry rereads the object and reapplies the entire batch. Waiting is bounded
// and cancellable, including for a server that continues returning 429.
func retryMasterManifest(ctx context.Context, logger *logrus.Entry, err error, attempt, maxAttempts int) error {
	var apiErr *googleapi.Error
	conflict := errors.As(err, &apiErr) && apiErr.Code == 412
	if (!conflict && !storage.ShouldRetry(err)) || attempt >= maxAttempts {
		return err
	}
	delay := time.Second << uint(attempt-1)
	if delay > 10*time.Second {
		delay = 10 * time.Second
	}
	delay += time.Duration(rand.Intn(200)) * time.Millisecond
	logger.WithError(err).WithField("attempt", attempt).Warn("Retrying master manifest update")
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
