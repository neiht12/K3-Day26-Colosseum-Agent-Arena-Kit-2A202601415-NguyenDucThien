VENV := .venv

# Keep the documented make targets usable on both POSIX and Windows hosts.
# GNU make on Windows sets OS=Windows_NT; the venv layout is the only path
# difference needed by the Python-backed targets below.
ifeq ($(OS),Windows_NT)
SHELL := cmd.exe
.SHELLFLAGS := /C
PY := python
BIN := $(VENV)\Scripts
else
PY := python3.12
BIN := $(VENV)/bin
endif

ifeq ($(OS),Windows_NT)
PYTHON := $(BIN)\python.exe
else
PYTHON := $(BIN)/python
endif
BOT ?= rookie
ROUNDS ?= 10
UI_FLAGS ?=
# GNU Make variable names are case-sensitive. Accept singular spellings so
# both `ROUND=15` and `round=15` behave like `ROUNDS=15`.
ifneq ($(origin ROUND),undefined)
ROUNDS := $(ROUND)
endif
ifneq ($(origin round),undefined)
ROUNDS := $(round)
endif
# `AS` is a GNU make BUILT-IN (the assembler, default `as`), so `AS ?= all`
# never fired and a plain `make spar BOT=rookie` ran `spar.py --as as`, which
# argparse rejects. `?=` only assigns when a variable is UNDEFINED, and make had
# already defined this one. Keep the documented `AS=defender` interface working
# by honouring AS only when it really came from the command line.
ROLE ?= all
ifeq ($(origin AS),command line)
ROLE := $(AS)
endif

.PHONY: install spar ui validate qualify submit test clean check-no-key

# --seed is REQUIRED: `uv venv` alone creates a venv with no pip, so the next
# line would otherwise die with "No module named pip" on a fresh clone. The
# stdlib fallback seeds pip on its own.
install:
	uv venv --python 3.12 --seed $(VENV) || $(PY) -m venv $(VENV)
	$(PYTHON) -m pip install -q --upgrade pip
	$(PYTHON) -m pip install -q pytest
	@echo "ready. no api key needed, ever."

spar:
	$(PYTHON) -X utf8 spar.py --bot $(BOT) --as $(ROLE) --rounds $(ROUNDS)

ui:
	$(PYTHON) -m kit.arena_ui.build_ui
	$(PYTHON) -X utf8 spar.py --bot $(BOT) --as $(ROLE) --rounds $(ROUNDS) --ui --quiet
	$(PYTHON) -X utf8 serve_ui.py --rounds $(ROUNDS) $(UI_FLAGS)

# Always validate against the REAL exported world. Without --world the validator falls
# back to kit/world/fixture.py's ~40-page synthetic world, where every real anchor fails
# to resolve — 15 spurious failures that look like a broken deck and are not.
WORLD := $(firstword $(wildcard kit/world/*/manifest.json))

validate:
	$(PYTHON) -c "import pathlib; p=pathlib.Path(r'$(WORLD)'); assert p.is_file(), \"no world exported - run 'make check-world'\""
	$(PYTHON) validate_deck.py deck/deck.json deck/lineup.json --world $(dir $(WORLD))

ifeq ($(OS),Windows_NT)
validate-bots:
	$(PYTHON) -c "import subprocess; [subprocess.run([r'$(PYTHON)', 'validate_deck.py', f'bots/{b}/deck.json', f'bots/{b}/lineup.json', '--world', r'$(dir $(WORLD))']) for b in ('rookie','operator','adversary')]"
else
validate-bots:
	@for b in rookie operator adversary; do \
		printf "%-12s " $$b; \
		$(BIN)/python validate_deck.py bots/$$b/deck.json bots/$$b/lineup.json \
			--world $(dir $(WORLD)) 2>&1 | tail -1; \
	done
endif

# `qualify` used to run a `qualify.py` that was never written, writing a
# `submissions/radar.json` that NOTHING in either repo reads. It is not a
# missing dependency, it is a promise that was never wired up. The student's
# real conformance check is the public suite: `make test`.
qualify:
	@echo "make qualify: retired — nothing consumed submissions/radar.json."
	@echo "Your conformance check is 'make test' (the public suite)."
	@echo "Then: make validate && make submit TEAM=<your-team>"
	@exit 1

# NOT `validate qualify` — qualify is retired (above), and kit.submit REQUIRES
# --team, which this target never passed, so `make submit` failed twice over.
submit: validate
	$(PYTHON) -c "assert '$(TEAM)', 'usage: make submit TEAM=<your-team-name>'"
	$(PYTHON) -m kit.submit --team $(TEAM)

ifeq ($(OS),Windows_NT)
test: check-no-key
	$(PYTHON) -c "import os,pathlib; p=pathlib.Path(r'$(CURDIR)')/'.test-tmp'; p.mkdir(exist_ok=True); os.environ.update(TMP=str(p), TEMP=str(p)); import pytest; raise SystemExit(pytest.main(['-p','no:cacheprovider','--basetemp',str(p/'pytest'),'tests/']))"
else
test: check-no-key
	$(PYTHON) -m pytest tests/
endif

# The referee in kit/ is a hash-synced copy of the arena's (CONTRACTS.md 2.4): students
# must be able to run the exact verifier that will judge them, or prosecution is guesswork.
check-referee:
	@$(PYTHON) -c "import pathlib; assert pathlib.Path('kit/referee').is_dir(), 'kit/referee missing - ask your instructor to run tools.sync_referee'"
	@$(PYTHON) -c "from kit.referee.rubric import CLASSES; from kit.referee.adjudicate import LOCAL_ONLY; print(f'referee: {len(CLASSES)} classes, local_only={LOCAL_ONLY}')"

# The world artifact is exported by the instructor; without it nothing can run.
check-world:
	@$(PYTHON) -c "import json,glob,pathlib; paths=sorted(glob.glob('kit/world/*/manifest.json')); assert paths, 'no world in kit/world/ - ask your instructor for the world artifact'; m=json.loads(pathlib.Path(paths[-1]).read_text()); print('world', m.get('world_id'), '-', m.get('counts',{}).get('__total__', sum(m.get('counts',{}).values())), 'pages')"
	@$(PYTHON) -c "import glob; paths=glob.glob('kit/world/*/truth.json'); assert not paths, 'FAIL: truth.json must never ship to students'"

doctor: check-no-key check-world check-referee validate
	@echo "ready to spar."

# A shipped gate, not a formality: the student kit must contain no model client and no
# API key. It is a real module with its own tests, not a grep — the grep version fired on
# the sandbox's own network-denial probe and on the injection fixtures that have to NAME
# the key to be realistic. Naming a secret is not leaking one; see kit/gate_no_key.py.
check-no-key:
	@$(PYTHON) -m kit.gate_no_key

ifeq ($(OS),Windows_NT)
clean:
	$(PYTHON) -c "import pathlib,shutil; [shutil.rmtree(p) for p in pathlib.Path('.').rglob('__pycache__') if p.is_dir()]; shutil.rmtree('.pytest_cache', ignore_errors=True)"

else
clean:
	find . -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
	rm -rf .pytest_cache
endif
