CC ?= cc
CFLAGS ?= -O2
STRICT = -std=c11 -Wall -Wextra -Werror -Wpedantic
HELPER = ../priv/tmux_owned_io
NOTICE = ../priv/owned_io.LICENSE

.PHONY: all clean
all: $(HELPER) $(NOTICE)

$(HELPER): owned_io.c Makefile
	mkdir -p ../priv
	$(CC) $(CFLAGS) $(STRICT) owned_io.c -o $@

$(NOTICE): LICENSE
	mkdir -p ../priv
	cp LICENSE $@

clean:
	rm -f $(HELPER) $(NOTICE)
