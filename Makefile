.PHONY: build run bundle install dmg clean

build:
	swift build -c release

run: bundle
	open GitCount.app

bundle: build
	bash bundle.sh

install: bundle
	@cp -r GitCount.app /Applications/GitCount.app
	@echo "Installed to /Applications/GitCount.app"
	@email=$$(git config user.email 2>/dev/null); \
	if [ -n "$$email" ]; then \
		existing=$$(defaults read com.gitcount.app authorEmails 2>/dev/null); \
		if [ "$$existing" = "" ] || echo "$$existing" | grep -q "()"; then \
			defaults write com.gitcount.app authorEmails -array "$$email"; \
			echo "Configured author email: $$email"; \
			echo "Open Settings in the app to add more emails."; \
		fi; \
	fi
	@if ! gh auth status >/dev/null 2>&1; then \
		echo ""; \
		echo "NOTE: GitHub CLI is not authenticated."; \
		echo "Run 'gh auth login' to enable GitHub integration."; \
	fi

dmg: bundle
	@rm -rf /tmp/GitCount-dmg GitCount.dmg
	@mkdir -p /tmp/GitCount-dmg
	@cp -r GitCount.app /tmp/GitCount-dmg/
	@ln -s /Applications /tmp/GitCount-dmg/Applications
	@hdiutil create -volname "GitCount" -srcfolder /tmp/GitCount-dmg -ov -format UDZO GitCount.dmg
	@rm -rf /tmp/GitCount-dmg
	@echo "Created GitCount.dmg"

clean:
	swift package clean
	rm -rf GitCount.app GitCount.dmg
