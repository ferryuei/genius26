## Switch10G Makefile
IVERILOG  = iverilog
VVP       = vvp
WORK      = work

SRC = rtl/common/fdb_table.v \
      rtl/common/vlan_table.v \
      rtl/control/stp_ctrl.v \
      rtl/ingress/ingress_pipeline.v \
      rtl/fabric/switch_fabric.v \
      rtl/egress/egress_pipeline.v \
      rtl/l2_switch_top.v

TB  = tb/tb_l2_switch.v

sim:
	$(IVERILOG) -g2012 -o $(WORK)/l2_switch_sim $(SRC) $(TB)
	$(VVP) $(WORK)/l2_switch_sim

wave:
	gtkwave l2_switch_tb.vcd &

clean:
	rm -f $(WORK)/l2_switch_sim l2_switch_tb.vcd

.PHONY: sim wave clean
