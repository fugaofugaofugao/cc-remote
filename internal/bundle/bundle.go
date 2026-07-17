package bundle

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/fugaofugaofugao/cc-remote/internal/manifest"
)

func HashFile(path string) (manifest.Payload, error) {
	f, err := os.Open(path)
	if err != nil {
		return manifest.Payload{}, err
	}
	defer f.Close()

	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return manifest.Payload{}, err
	}
	return manifest.Payload{SHA256: hex.EncodeToString(h.Sum(nil)), Size: n}, nil
}

func CollectPayloads(root string) ([]manifest.Payload, error) {
	var payloads []manifest.Payload
	if _, err := os.Stat(root); os.IsNotExist(err) {
		return payloads, nil
	}
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		p, err := HashFile(path)
		if err != nil {
			return err
		}
		p.Path = filepath.ToSlash(filepath.Join("payloads", rel))
		payloads = append(payloads, p)
		return nil
	})
	return payloads, err
}

func CreateZip(outPath string, files map[string]string) error {
	if err := os.MkdirAll(filepath.Dir(outPath), 0o700); err != nil {
		return err
	}
	out, err := os.Create(outPath)
	if err != nil {
		return err
	}
	defer out.Close()

	zw := zip.NewWriter(out)
	defer zw.Close()

	for dst, src := range files {
		if err := addFile(zw, dst, src); err != nil {
			return err
		}
	}
	return nil
}

func addFile(zw *zip.Writer, dst, src string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	info, err := in.Stat()
	if err != nil {
		return err
	}
	header, err := zip.FileInfoHeader(info)
	if err != nil {
		return err
	}
	header.Name = strings.TrimPrefix(filepath.ToSlash(dst), "/")
	header.Method = zip.Deflate
	w, err := zw.CreateHeader(header)
	if err != nil {
		return err
	}
	_, err = io.Copy(w, in)
	return err
}
