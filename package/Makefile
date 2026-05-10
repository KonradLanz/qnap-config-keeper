# Entware-Makefile für qnap-config-keeper
# Erstellt ein .ipk-Paket für opkg install
#
# Nutzung:
#   make package   -- erstellt qnap-config-keeper_0.1.0_x86_64.ipk
#   make clean     -- entfernt build-Artefakte

PKG_NAME    = qnap-config-keeper
PKG_VERSION = 0.1.0
PKG_ARCH    = x86_64
IPK_NAME    = $(PKG_NAME)_$(PKG_VERSION)_$(PKG_ARCH).ipk

BUILD_DIR   = build
DATA_DIR    = $(BUILD_DIR)/data
CONTROL_DIR = $(BUILD_DIR)/control

.PHONY: package clean

package: clean
	# Verzeichnisstruktur
	mkdir -p $(DATA_DIR)/opt/bin
	mkdir -p $(DATA_DIR)/opt/share/$(PKG_NAME)
	mkdir -p $(DATA_DIR)/opt/etc
	mkdir -p $(CONTROL_DIR)

	# Script
	cp ../qnap-config-keeper.sh $(DATA_DIR)/opt/bin/$(PKG_NAME).sh
	cp ../qnap-config-keeper.sh $(DATA_DIR)/opt/share/$(PKG_NAME)/
	chmod +x $(DATA_DIR)/opt/bin/$(PKG_NAME).sh

	# Beispiel-Config
	cp conffiles $(CONTROL_DIR)/conffiles
	echo '# qnap-config-keeper Konfiguration' > \
	  $(DATA_DIR)/opt/etc/config-keeper.conf

	# Control-Dateien
	cp control $(CONTROL_DIR)/control
	cp postinst $(CONTROL_DIR)/postinst
	chmod +x $(CONTROL_DIR)/postinst

	# tar-Archive (busybox-kompatibel)
	cd $(DATA_DIR) && tar czf ../../data.tar.gz .
	cd $(CONTROL_DIR) && tar czf ../../control.tar.gz .
	echo '2.0' > $(BUILD_DIR)/debian-binary

	# .ipk zusammenbauen (ar)
	ar r $(IPK_NAME) \
	  $(BUILD_DIR)/debian-binary \
	  control.tar.gz \
	  data.tar.gz

	rm -f control.tar.gz data.tar.gz
	@echo ""
	@echo "Fertig: $(IPK_NAME)"
	@echo "Install: opkg install $(IPK_NAME)"

clean:
	rm -rf $(BUILD_DIR) *.ipk control.tar.gz data.tar.gz
