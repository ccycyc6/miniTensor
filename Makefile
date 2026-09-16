VERILATOR ?= verilator
OBJ_DIR    := $(CURDIR)/obj_dir
TOP        := tb_vpu_vector_controller
BIN        := $(OBJ_DIR)/V$(TOP)
WAVE_FILE  := $(CURDIR)/vector_controller.vcd

VERILATOR_FLAGS ?=

SOURCES = $(VECTOR_SOURCES)

NPC_SOURCES := \
	$(CURDIR)/CV-X-IF_Adapter/core_v_xif.sv \
	$(CURDIR)/Controller/vpu_pkg.sv \
	$(CURDIR)/Vector_Processing_Unit/vpu_vector_regfile.sv \
	$(CURDIR)/Vector_Processing_Unit/Vector_ALU/vpu_vector_alu.sv \
	$(CURDIR)/Controller/vpu_vector_controller.sv \
	$(CURDIR)/CV-X-IF_Adapter/vpu_vector_npc_adapter.sv \
	$(CURDIR)/CV-X-IF_Adapter/tb_vpu_vector_npc_adapter.sv

VECTOR_SOURCES := \
	$(CURDIR)/Controller/vpu_pkg.sv \
	$(CURDIR)/Vector_Processing_Unit/vpu_vector_regfile.sv \
	$(CURDIR)/Vector_Processing_Unit/Vector_ALU/vpu_vector_alu.sv \
	$(CURDIR)/Controller/vpu_vector_controller.sv \
	$(CURDIR)/Controller/tb_vpu_vector_controller.sv

UB_SOURCES := \
	$(CURDIR)/Unified_Buffer/unified_buffer.sv \
	$(CURDIR)/Unified_Buffer/tb_unified_buffer.sv

DMA_SOURCES := \
	$(CURDIR)/Unified_Buffer/unified_buffer.sv \
	$(CURDIR)/VPU-Uncached-Master/DMA/vpu_dma.sv \
	$(CURDIR)/VPU-Uncached-Master/DMA/tb_vpu_dma.sv

.PHONY: sim npc-sim vrf-sim vector-sim ub-sim dma-sim wave build clean

sim: vector-sim

npc-sim:
	mkdir -p $(OBJ_DIR)/npc
	CCACHE_DISABLE=1 $(VERILATOR) --binary --timing --Wall --Wno-fatal \
		--Mdir $(OBJ_DIR)/npc --top-module tb_vpu_vector_npc_adapter $(NPC_SOURCES)
	$(OBJ_DIR)/npc/Vtb_vpu_vector_npc_adapter

vrf-sim:
	mkdir -p $(OBJ_DIR)/vrf
	CCACHE_DISABLE=1 $(VERILATOR) --binary --timing --Wall --Wno-fatal \
		--Mdir $(OBJ_DIR)/vrf --top-module tb_vpu_vector_regfile \
		$(CURDIR)/Vector_Processing_Unit/vpu_vector_regfile.sv \
		$(CURDIR)/Vector_Processing_Unit/tb_vpu_vector_regfile.sv
	$(OBJ_DIR)/vrf/Vtb_vpu_vector_regfile

vector-sim: build
	$(BIN)

ub-sim:
	mkdir -p $(OBJ_DIR)/ub
	CCACHE_DISABLE=1 $(VERILATOR) --binary --timing --Wall --Wno-fatal \
		--Mdir $(OBJ_DIR)/ub --top-module tb_unified_buffer $(UB_SOURCES)
	$(OBJ_DIR)/ub/Vtb_unified_buffer

dma-sim:
	mkdir -p $(OBJ_DIR)/dma
	CCACHE_DISABLE=1 $(VERILATOR) --binary --timing --Wall --Wno-fatal \
		--Mdir $(OBJ_DIR)/dma --top-module tb_vpu_dma $(DMA_SOURCES)
	$(OBJ_DIR)/dma/Vtb_vpu_dma

wave:
	$(MAKE) sim VERILATOR_FLAGS="--trace -DTRACE"
	@test -f $(WAVE_FILE)
	@echo "waveform: $(WAVE_FILE)"

build:
	CCACHE_DISABLE=1 $(VERILATOR) --binary --timing --Wall --Wno-fatal \
		$(VERILATOR_FLAGS) --Mdir $(OBJ_DIR) --top-module $(TOP) $(SOURCES)

clean:
	rm -rf $(OBJ_DIR) $(WAVE_FILE)
