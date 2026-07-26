VERSION := $(shell grep 'version' crop_enhancer_info.lua | sed 's/.*"\(.*\)".*/\1/')
DIST := crop_enhancer.koplugin

.PHONY: release clean

release:
	mkdir -p $(DIST)
	cp *.lua $(DIST)/
	cp -r l10n $(DIST)/
	zip -r $(DIST)-$(VERSION).zip $(DIST)
	rm -rf $(DIST)
	@echo "$(DIST)-$(VERSION).zip"

clean:
	rm -rf crop_enhancer-*.zip crop_enhancer.koplugin/
