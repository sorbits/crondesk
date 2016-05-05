BUILDDIR ?= .

$(BUILDDIR)/crondesk: src/crondesk.swift
	xcrun --sdk macosx swiftc -target x86_64-apple-macosx10.10 -O -o $@ $<

install: $(BUILDDIR)/crondesk
	@$< install

.PHONY: install
