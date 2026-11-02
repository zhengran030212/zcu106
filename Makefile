.PHONY: check sim probe mine
check:
	PYTHONPATH=host python3 -m unittest discover -s tests -v
	verilator --lint-only --top-module btc_axi rtl/*.sv rtl/*.v
	python3 sim/run_tests.py
	python3 sim/test_axi.py
sim:
	python3 sim/run_tests.py
	python3 sim/test_axi.py
probe:
	PYTHONPATH=host python3 -m btc_lottery --probe
mine:
	PYTHONPATH=host python3 -m btc_lottery --backend openocd
