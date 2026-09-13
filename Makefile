VERILATOR ?= verilator
OBJ_DIR    := $(CURDIR)/obj_dir
TOP        := tb_vpu_basic
BIN        := $(OBJ_DIR)/V$(TOP)
WAVE_FILE  := $(CURDIR)/vpu_basic.vcd

VERILATOR_FLAGS ?=

SOURCES := \
	$(CURDIR)/core_v_xif.sv \
	$(CURDIR)/vpu_pkg.sv \
	$(CURDIR)/vpu_basic.sv \
	$(CURDIR)/tb_vpu_basic.sv

NPC_SOURCES := \
	$(CURDIR)/core_v_xif.sv \
	$(CURDIR)/vpu_pkg.sv \
	$(CURDIR)/vpu_basic.sv \
	$(CURDIR)/vpu_npc_model.sv \
	$(CURDIR)/tb_vpu_npc_model.sv

.PHONY: sim npc-sim wave build clean

sim: build
	$(BIN)

npc-sim:
	mkdir -p $(OBJ_DIR)/npc
	CCACHE_DISABLE=1 $(VERILATOR) --binary --timing --Wall --Wno-fatal \
		--Mdir $(OBJ_DIR)/npc --top-module tb_vpu_npc_model $(NPC_SOURCES)
	$(OBJ_DIR)/npc/Vtb_vpu_npc_model

wave:
	$(MAKE) sim VERILATOR_FLAGS="--trace -DTRACE"
	@test -f $(WAVE_FILE)
	@echo "waveform: $(WAVE_FILE)"

build:
	CCACHE_DISABLE=1 $(VERILATOR) --binary --timing --Wall --Wno-fatal \
		$(VERILATOR_FLAGS) --Mdir $(OBJ_DIR) --top-module $(TOP) $(SOURCES)

clean:
	rm -rf $(OBJ_DIR) $(WAVE_FILE)
