//go:build !android && !darwin

package libXray

import "github.com/xtls/libxray/xray"

// SetTunFd sets the TUN file descriptor.
// Call this BEFORE RunXray/RunXrayFromJSON.
func SetTunFd(fd int64) {
	xray.SetTunFd(int32(fd))
}
