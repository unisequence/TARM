include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-tarm
PKG_VERSION:=0.6.0
PKG_RELEASE:=10
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-tarm
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=TARM web interface
  DEPENDS:=+luci-base +tarm
  PKGARCH:=all
endef

define Build/Compile
endef

define Package/luci-app-tarm/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/tarm
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/tarm/main.js $(1)/www/luci-static/resources/view/tarm/main.js
	$(INSTALL_DIR) $(1)/www/luci-static/resources/tarm
	$(INSTALL_DATA) ./htdocs/luci-static/resources/tarm/catalog.txt $(1)/www/luci-static/resources/tarm/catalog.txt
	$(INSTALL_DATA) ./htdocs/luci-static/resources/tarm/presets.css $(1)/www/luci-static/resources/tarm/presets.css
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-tarm.json $(1)/usr/share/luci/menu.d/luci-app-tarm.json
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-tarm.json $(1)/usr/share/rpcd/acl.d/luci-app-tarm.json
endef

$(eval $(call BuildPackage,luci-app-tarm))
