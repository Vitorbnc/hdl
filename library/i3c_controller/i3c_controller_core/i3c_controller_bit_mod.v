// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2024 Analog Devices, Inc. All rights reserved.
//
// In this HDL repository, there are many different and unique modules, consisting
// of various HDL (Verilog or VHDL) components. The individual modules are
// developed independently, and may be accompanied by separate and unique license
// terms.
//
// The user should read each of these license terms, and understand the
// freedoms and responsibilities that he or she has by using this source/core.
//
// This core is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
// A PARTICULAR PURPOSE.
//
// Redistribution and use of source or resulting binaries, with or without modification
// of this file, are permitted under one of the following two license terms:
//
//   1. The GNU General Public License version 2 as published by the
//      Free Software Foundation, which can be found in the top level directory
//      of this repository (LICENSE_GPL2), and also online at:
//      <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
//
// OR
//
//   2. An ADI specific BSD license, which can be found in the top level directory
//      of this repository (LICENSE_ADIBSD), and also on-line at:
//      https://github.com/analogdevicesinc/hdl/blob/main/LICENSE_ADIBSD
//      This will allow to generate bit files and not release the source code,
//      as long as it attaches to an ADI device.
//
// ***************************************************************************
// ***************************************************************************
/**
 * Modulates the SDA and SCL lanes.
 * SCL high time is fixed at 40ns in I3C mode:
 * * 4 clock cycles at 100MHz clk.
 * * 2 clock cycles at 50MHz clk.
 * Parameter CLK_MOD tunes the number of clock cycles to module one lane bus bit,
 * to achieve 12.5MHz at the maximum speed grade, set:
 * * CLK_MOD = 0, clk = 100MHz
 * * CLK_MOD = 1, clk = 50MHz
 */

`timescale 1ns/100ps

`include "i3c_controller_bit_mod.vh"

module i3c_controller_bit_mod #(
  parameter CLK_MOD = 0
) (
  input reset_n,
  input clk,

  // Bit Modulation Command

  input  [`MOD_BIT_CMD_WIDTH:0] cmdb,
  input  cmdb_valid,
  output cmdb_ready,

  // Mux to alternative logic to support I²C devices.
  input  i2c_mode,
  // Indicates that the bus is not transferring,
  // is *not* bus available condition because does not wait 1s after P.
  output nop,
  // 0:  1.56MHz
  // 1:  3.12MHz
  // 2:  6.25MHz
  // 3: 12.50MHz
  input [1:0] scl_pp_sg, // SCL push-pull speed grade.

  output reg rx,
  output     rx_valid,

  // Bus drive signals

  output     scl,
  output reg sdo,
  input      sdi,
  output reg t
);

  localparam [1:0] SM_SETUP    = 0;
  localparam [1:0] SM_STALL    = 1;
  localparam [1:0] SM_SCL_LOW  = 2;
  localparam [1:0] SM_SCL_HIGH = 3;

  localparam COUNT_INCR = CLK_MOD ? 2 : 1;

  reg [`MOD_BIT_CMD_WIDTH:0] cmdb_r;
  reg [1:0] pp_sg;
  reg [5:0] count; // Worst-case: 1.56MHz, 32-bits per half-bit.
  reg       sr;
  reg       i2c_mode_reg;
  reg       i2c_scl_reg;
  reg [3:0] count_delay;
  reg [1:0] sm;

  wire [`MOD_BIT_CMD_WIDTH:2] st;
  wire [1:CLK_MOD] count_high;
  wire [3:0] scl_posedge_multi;
  wire       t_w;
  wire       t_w2;
  wire       sdo_w;
  wire       scl_posedge;
  wire       sr_sda;
  wire       sr_scl;
  wire       i3c_scl_posedge;
  wire       i2c_scl;
  wire       i2c_scl_posedge;
  wire [1:0] ss;

  always @(posedge clk) begin
    count <= 4;
    i2c_scl_reg <= i2c_scl;
    count_delay <= {count_delay[2:0], count[5]};
    if (!reset_n) begin
      sm <= SM_SETUP;
      cmdb_r <= {`MOD_BIT_CMD_NOP_, 2'b01};
      pp_sg <= 2'b00;
      sr <= 1'b0;
      i2c_mode_reg <= 1'b0;
    end else begin
      if (sm == SM_SETUP & cmdb_valid) begin
        i2c_mode_reg <= i2c_mode;
      end

      case (sm)
        SM_SCL_LOW: begin
          if (scl_posedge) begin
            sm <= SM_SCL_HIGH;
          end
        end
        SM_SCL_HIGH: begin
          if (&count_high) begin
            if (st == `MOD_BIT_CMD_STOP_) begin
              sm <= SM_SETUP;
            end else begin
              sm <= SM_STALL;
            end
          end
        end
        SM_SETUP: begin
          sr <= 1'b0;
        end
        SM_STALL: begin
        end
      endcase

      if (cmdb_ready) begin
        if (cmdb_valid) begin
          cmdb_r <= cmdb[4:2] != `MOD_BIT_CMD_START_ ? cmdb : {cmdb[4:2], 1'b0, cmdb[0]};
          // CMDW_MSG_RX is push-pull, but the Sr to stop from the controller side is open drain.
          pp_sg <= cmdb[1] & cmdb[4:2] != `MOD_BIT_CMD_START_ ? scl_pp_sg : 2'b00;
          sm <= SM_SCL_LOW;
        end else begin
          cmdb_r <= {`MOD_BIT_CMD_NOP_, 2'b01};
        end
      end

      if (!cmdb_ready) begin
        count <= count + COUNT_INCR;
      end

      if (sm == SM_SETUP) begin
        sr <= 1'b0;
      end else if (cmdb_ready) begin
        sr <= 1'b1;
      end
    end
  end

  generate if (CLK_MOD) begin
    // Is short on one clock cycle at clk 50MHz, scl 12.5MHz,
    // but due to the lower clk frequency, timing slack to propagate is better.
    always @(*) begin
      rx = sdi === 1'b0 ? 1'b0 : 1'b1;
    end
  end else begin
    always @(posedge clk) begin
      rx <= sdi === 1'b0 ? 1'b0 : 1'b1;
    end
  end
  endgenerate

  always @(posedge clk) begin
    // To guarantee thd_pp > 3ns.
    sdo <= sdo_w;
    t <= t_w2;
  end

  genvar i;
  generate
    for (i = 0; i < 4; i = i+1) begin: gen_scl
      assign scl_posedge_multi[i] = &count[i+2:CLK_MOD];
    end
  endgenerate

  assign scl_posedge = scl_posedge_multi[3-pp_sg];
  assign count_high = count[1:CLK_MOD];
  assign cmdb_ready = (sm == SM_SETUP) ||
                      (sm == SM_STALL) ||
                      (sm == SM_SCL_HIGH & &count_high);
  assign ss = cmdb_r[1:0];
  assign st = cmdb_r[`MOD_BIT_CMD_WIDTH:2];

  // Used to generate Sr with generous timing (locked in open drain speed).
  assign sr_sda = ((~count[4] & count[5]) | ~count[5]) & sm == SM_SCL_LOW;
  assign sr_scl = count[5] | sm == SM_SCL_HIGH;
  assign i2c_scl = count_delay[3];

  assign i2c_scl_posedge = i2c_scl & ~i2c_scl_reg;
  assign i3c_scl_posedge = (sm == SM_SCL_HIGH & &(~count_high));

  // Multi-cycle-path worst-case:
  // * 4 clks (12.5MHz, half-bit ack, 100MHz clk)
  // * 2 clks (12.5MHz, half-bit ack, 50MHz clk)
  assign rx_valid = i2c_mode_reg ? i2c_scl_posedge :
                    CLK_MOD ? scl_posedge : i3c_scl_posedge;

  assign sdo_w = st == `MOD_BIT_CMD_START_   ? sr_sda :
                 st == `MOD_BIT_CMD_STOP_    ? 1'b0 :
                 st == `MOD_BIT_CMD_WRITE_   ? ss[0] :
                 st == `MOD_BIT_CMD_ACK_SDR_ ?
                   (i2c_mode_reg ? 1'b1 : (sm == SM_SCL_HIGH ? rx : 1'b1)) :
                 st == `MOD_BIT_CMD_ACK_IBI_ ?
                   (sm == SM_SCL_HIGH ? 1'b1 : 1'b0) :
                 1'b1;

  // Expression ...
  //assign t_w = st == `MOD_BIT_CMD_STOP_    ? 1'b0 :
  //             st == `MOD_BIT_CMD_START_   ? 1'b0 :
  //             st == `MOD_BIT_CMD_READ_    ? 1'b0 :
  //             st == `MOD_BIT_CMD_ACK_SDR_ ? 1'b0 :
  //             ss[1];
  // ... gets optimized to
  assign t_w  = st[4] ? 1'b0 : ss[1];
  assign t_w2 = ~t_w & sdo_w ? 1'b1 : 1'b0;

  assign scl = st == `MOD_BIT_CMD_START_ ? (sr ? sr_scl : 1'b1) :
               i2c_mode_reg ? (i2c_scl || sm == SM_SETUP) :
               (~(sm == SM_SCL_LOW || sm == SM_STALL));

  assign nop = st == `MOD_BIT_CMD_NOP_ & sm == SM_SETUP;

endmodule
