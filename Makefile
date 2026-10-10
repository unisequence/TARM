include $(TOPDIR)/rules.mk

PKG_NAME:=tarm
PKG_VERSION:=0.6.0
PKG_RELEASE:=8
PKG_LICENSE:=MIT
PKG_MAINTAINER:=local

include $(INCLUDE_DIR)/package.mk

define Package/tarm
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Tiny Amnezia Routing Manager
  DEPENDS:=+dnsmasq-full +nftables-json +ip-full +flock +uclient-fetch +ca-bundle +amneziawg-tools +kmod-amneziawg
  PKGARCH:=all
endef

define Package/tarm/description
  Domain and IP list routing over a native AmneziaWG interface.
endef

define Package/tarm/conffiles
/etc/config/tarm
/etc/tarm/tunnel.conf
endef

define Build/Compile
endef

define Package/tarm/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
line='17 4 * * * /usr/bin/tarm update >/dev/null 2>&1'
if [ -f /etc/crontabs/root ]; then
	grep -Fvx "$$line" /etc/crontabs/root > /etc/crontabs/root.tarm-new || true
	mv /etc/crontabs/root.tarm-new /etc/crontabs/root
	chmod 600 /etc/crontabs/root
	/etc/init.d/cron restart >/dev/null 2>&1 || true
fi
endef

define Package/tarm/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/tarm/manual $(1)/etc/init.d $(1)/etc/uci-defaults $(1)/etc/hotplug.d/iface $(1)/etc/hotplug.d/ntp $(1)/usr/bin $(1)/usr/share/tarm/presets
	touch $(1)/etc/tarm/tunnel.conf
	chmod 600 $(1)/etc/tarm/tunnel.conf
	touch $(1)/etc/tarm/import.txt
	chmod 600 $(1)/etc/tarm/import.txt
	touch $(1)/etc/tarm/tunnel.upload
	chmod 600 $(1)/etc/tarm/tunnel.upload
	$(INSTALL_CONF) ./files/etc/config/tarm $(1)/etc/config/tarm
	$(INSTALL_BIN) ./files/etc/init.d/tarm $(1)/etc/init.d/tarm
	$(INSTALL_BIN) ./files/etc/uci-defaults/95-tarm-cron $(1)/etc/uci-defaults/95-tarm-cron
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/95-tarm $(1)/etc/hotplug.d/iface/95-tarm
	$(INSTALL_BIN) ./files/etc/hotplug.d/ntp/95-tarm $(1)/etc/hotplug.d/ntp/95-tarm
	$(INSTALL_BIN) ./files/usr/bin/tarm $(1)/usr/bin/tarm
	$(INSTALL_DATA) ./files/usr/share/tarm/core.sh $(1)/usr/share/tarm/core.sh
	$(INSTALL_DATA) ./files/usr/share/tarm/telegram-cidr.txt $(1)/usr/share/tarm/telegram-cidr.txt
	$(INSTALL_DATA) ./files/usr/share/tarm/meta-cidr.txt $(1)/usr/share/tarm/meta-cidr.txt
	$(INSTALL_DATA) ./files/usr/share/tarm/presets/* $(1)/usr/share/tarm/presets/
endef

$(eval $(call BuildPackage,tarm))
