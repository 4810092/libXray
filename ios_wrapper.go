//go:build darwin

package libXray

import (
	"os"
	"strconv"

	c "github.com/xtls/libxray/controller"
	"github.com/xtls/libxray/dns"
	"github.com/xtls/xray-core/common/platform"
)

// SocketProtector is a callback interface for iOS Network Extension socket protection.
// The Swift implementation should call setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &ifIndex, 4)
// to bind the socket to the physical interface (en0/pdp_ip0), bypassing VPN routing.
type SocketProtector interface {
	ProtectFd(int) bool
}

func InitDns(controller SocketProtector, server string) {
	dns.InitDns(server, func(fd uintptr) {
		controller.ProtectFd(int(fd))
	})
}

func ResetDns() {
	dns.ResetDns()
}

func SetTunFd(fd int64) {
	_ = os.Setenv(platform.TunFdKey, strconv.FormatInt(fd, 10))
}

func ClearTunFd() {
	_ = os.Unsetenv(platform.TunFdKey)
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
