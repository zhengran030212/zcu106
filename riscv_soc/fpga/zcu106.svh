// ZCU106 PL: clock and reset come from the PS. DRAM is the PS HP port,
// not a MIG. Do not define KINTEX7 here; that path instantiates 7-series DDR.
`define ZCU106
`define ARIANE_DATA_WIDTH 64
