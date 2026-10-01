// =============================================================================
// File        : OmniBus_Config.vh
// Description : Unified OmniBus Architecture & Symmetric Multi-Core Configuration
//               Single Source of Truth for NUM_CORES across RTL, C, and Assembly.
//               Supported Configurations: 1, 2, or 4 Symmetric Cores.
// License     : MIT License
// =============================================================================

`ifndef OMNIBUS_CONFIG_VH
`define OMNIBUS_CONFIG_VH

// -----------------------------------------------------------------------------
// Core Topology Configuration
// -----------------------------------------------------------------------------
// Sets the default number of instantiated symmetric execution slices.
// Valid values: 1 (Uniprocessor), 2 (Dual-Core MP), 4 (Quad-Core MP Grid)
`define NUM_CORES 2

// -----------------------------------------------------------------------------
// Memory & FIFO Subsystem Parameters
// -----------------------------------------------------------------------------
`define DEFAULT_IMEM_SIZE 128
`define DEFAULT_FIFO_DEPTH 16
`define DEFAULT_BAUD_DIV 433

`endif // OMNIBUS_CONFIG_VH
