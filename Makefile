BUILDDIR ?= .

$(BUILDDIR)/crondesk: src/crondesk.swift
	xcrun --sdk macosx swiftc -O -o $@ $<

install: $(BUILDDIR)/crondesk
	@$< install

.PHONY: install
