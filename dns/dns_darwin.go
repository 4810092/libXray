//go:build darwin

package dns

import (
	"context"
	"net"
	"syscall"
	"time"
)

// Give a callback when parsing server domain. Useful for iOS development.
func InitDns(dns string, controller func(fd uintptr)) {
	net.DefaultResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			dialer := makeDialer(controller)
			return dialer.DialContext(ctx, network, dns)
		},
	}
}

func makeDialer(controller func(fd uintptr)) *net.Dialer {
	dialer := &net.Dialer{
		Timeout: time.Second * 16,
	}

	if controller != nil {
		dialer.Control = func(network, address string, c syscall.RawConn) error {
			return c.Control(controller)
		}
	}

	return dialer
}
