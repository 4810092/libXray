//go:build darwin

package libXray

import (
	c "github.com/xtls/libxray/controller"
)

// SocketProtector is a callback interface for iOS Network Extension socket protection.
// The Swift implementation should call setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &ifIndex, 4)
// to bind the socket to the physical interface (en0/pdp_ip0), bypassing VPN routing.
type SocketProtector interface {
	ProtectFd(int) bool
}

func RegisterDialerController(controller SocketProtector) {
	c.RegisterDialerController(func(fd uintptr) {
		controller.ProtectFd(int(fd))
	})
}

func RegisterListenerController(controller SocketProtector) {
	c.RegisterListenerController(func(fd uintptr) {
		controller.ProtectFd(int(fd))
	})
}
