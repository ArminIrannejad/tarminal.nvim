.PHONY: test lint fmt

DEPS := .deps
PLENARY := $(DEPS)/plenary.nvim
# pinned so a plenary change can never turn CI red on its own
PLENARY_REV := 74b06c6c75e4eeb3108ec01852001636d85a932b

$(PLENARY):
	git clone --filter=blob:none https://github.com/nvim-lua/plenary.nvim $(PLENARY)
	git -C $(PLENARY) checkout --quiet $(PLENARY_REV)

test: $(PLENARY)
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

lint:
	stylua --check lua/ plugin/ tests/

fmt:
	stylua lua/ plugin/ tests/
