//go:build android

package libXray

import (
	"os"
	"strconv"

	c "github.com/xtls/libxray/controller"
	"github.com/xtls/libxray/dns"
	"github.com/xtls/xray-core/common/platform"
)

type DialerController interface {
	ProtectFd(int) bool
}

func InitDns(controller DialerController, server string) {
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

func RegisterDialerController(controller DialerController) {
	c.RegisterDialerController(func(fd uintptr) {
		controller.ProtectFd(int(fd))
	})
}

func RegisterListenerController(controller DialerController) {
	c.RegisterListenerController(func(fd uintptr) {
		controller.ProtectFd(int(fd))
	})
}
