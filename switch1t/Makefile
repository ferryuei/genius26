.PHONY: check-rtl2 model-check rtl2-check

check-rtl2: model-check rtl2-check

model-check:
	python3 -m unittest discover -s model/tests -v
	python3 -m model.capacity_report

rtl2-check:
	$(MAKE) -C rtl2 all
