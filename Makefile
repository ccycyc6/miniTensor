VERILATOR ?= verilator
OBJ_DIR    := $(CURDIR)/obj_dir
TOP        := tb_vpu_basic
BIN        := $(OBJ_DIR)/V$(TOP)
WAVE_FILE  := $(CURDIR)/vpu_basic.vcd

VERILATOR_FLAGS ?=

SOURCES := \
	$(CURDIR)/core_v_xif.sv \
	$(CURDIR)/vpu_pkg.sv \
	$(CURDIR)/vpu_compute.sv \
	$(CURDIR)/vpu_basic.sv \
	$(CURDIR)/tb_vpu_basic.sv

NPC_SOURCES := \
	$(CURDIR)/core_v_xif.sv \
	$(CURDIR)/vpu_pkg.sv \
	$(CURDIR)/vpu_compute.sv \
	$(CURDIR)/vpu_basic.sv \
	$(CURDIR)/vpu_npc_model.sv \
	$(CURDIR)/tb_vpu_npc_model.sv

VECTOR_SOURCES := \
	$(CURDIR)/vpu_pkg.sv \
	$(CURDIR)/vpu_vector_regfile.sv \
	$(CURDIR)/vpu_vector_alu.sv \
	$(CURDIR)/vpu_vector_controller.sv \
	$(CURDIR)/tb_vpu_vector_controller.sv

.PHONY: sim npc-sim vrf-sim vector-sim wave build clean

sim: build
	$(BIN)

npc-sim:
	mkdir -p $(OBJ_DIR)/npc
	CCACHE_DISABLE=1 $(VERILATOR) --binary --timing --Wall --Wno-fatal \
		--Mdir $(OBJ_DIR)/npc --top-module tb_vpu_npc_model $(NPC_SOURCES)
	$(OBJ_DIR)/npc/Vtb_vpu_npc_model

vrf-sim:
	mkdir -p $(OBJ_DIR)/vrf
	CCACHE_DISABLE=1 $(VERILATOR) --binary --timing --Wall --Wno-fatal \
		--Mdir $(OBJ_DIR)/vrf --top-module tb_vpu_vector_regfile \
		$(CURDIR)/vpu_vector_regfile.sv $(CURDIR)/tb_vpu_vector_regfile.sv
	$(OBJ_DIR)/vrf/Vtb_vpu_vector_regfile

vector-sim:
	mkdir -p $(OBJ_DIR)/vector
	CCACHE_DISABLE=1 $(VERILATOR) --binary --timing --Wall --Wno-fatal \
		--Mdir $(OBJ_DIR)/vector --top-module tb_vpu_vector_controller \
		$(VECTOR_SOURCES)
	$(OBJ_DIR)/vector/Vtb_vpu_vector_controller

wave:
	$(MAKE) sim VERILATOR_FLAGS="--trace -DTRACE"
	@test -f $(WAVE_FILE)
	@echo "waveform: $(WAVE_FILE)"

build:
	CCACHE_DISABLE=1 $(VERILATOR) --binary --timing --Wall --Wno-fatal \
		$(VERILATOR_FLAGS) --Mdir $(OBJ_DIR) --top-module $(TOP) $(SOURCES)

clean:
	rm -rf $(OBJ_DIR) $(WAVE_FILE)
