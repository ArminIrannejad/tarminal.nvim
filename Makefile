.PHONY: test lint fmt

DEPS := .deps
PLENARY := $(DEPS)/plenary.nvim

$(PLENARY):
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY)

test: $(PLENARY)
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

lint:
	stylua --check lua/ plugin/ tests/

fmt:
	stylua lua/ plugin/ tests/
