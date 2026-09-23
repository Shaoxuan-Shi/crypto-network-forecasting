.PHONY: check demo figures install

install:
	Rscript scripts/install_required_packages.R

check:
	python3 -m py_compile scripts/download_binance_hourly_data.py scripts/prepare_crypto_hourly_dataset.py
	Rscript tests/test_data_contract.R

demo:
	Rscript scripts/run_demo.R

figures:
	Rscript scripts/create_portfolio_figures.R
