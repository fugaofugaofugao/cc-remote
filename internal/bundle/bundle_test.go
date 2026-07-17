package bundle

import (
	"archive/zip"
	"os"
	"path/filepath"
	"testing"
)

func TestCollectPayloads(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "windows", "dummy.txt")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("payload"), 0o644); err != nil {
		t.Fatal(err)
	}

	payloads, err := CollectPayloads(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(payloads) != 1 {
		t.Fatalf("expected one payload, got %d", len(payloads))
	}
	if payloads[0].Path != "payloads/windows/dummy.txt" {
		t.Fatalf("unexpected payload path: %s", payloads[0].Path)
	}
	if payloads[0].Size != int64(len("payload")) {
		t.Fatalf("unexpected payload size: %d", payloads[0].Size)
	}
}

func TestCreateZip(t *testing.T) {
	root := t.TempDir()
	src := filepath.Join(root, "source.txt")
	if err := os.WriteFile(src, []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(root, "out", "bundle.zip")
	if err := CreateZip(out, map[string]string{"nested/source.txt": src}); err != nil {
		t.Fatal(err)
	}

	zr, err := zip.OpenReader(out)
	if err != nil {
		t.Fatal(err)
	}
	defer zr.Close()
	if len(zr.File) != 1 {
		t.Fatalf("expected one zip entry, got %d", len(zr.File))
	}
	if zr.File[0].Name != "nested/source.txt" {
		t.Fatalf("unexpected zip entry: %s", zr.File[0].Name)
	}
}
