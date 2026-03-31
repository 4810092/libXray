//go:build !android && !darwin && !linux && !windows

package dns

func InitDns(_ string, _ string) {}
