// SimSDCard: SPI-mode SD card model for RTL simulation (dual-boot test).
//
// Enough of the protocol for fpga/src/main/resources/vcu118/sdboot:
//   CMD0, CMD8, CMD55 + ACMD41, CMD58, CMD16, CMD18 (multi-block read), CMD12.
// SDHC: CMD18's argument is a block (512 B) address. Each block is sent as
// FF FE <512 data bytes> <CRC16-CCITT/XMODEM, MSB first>, until CS goes high
// or CMD12 arrives. Anything else answers R1 = 0x04 (illegal command).
//
// SPI mode 0 (SCK idle low, sample on the rising edge, shift on the falling
// edge). SCK is oversampled with `clock`, so SCK must be several `clock`
// cycles per half period (sdboot: SPI_DIV >= 3 is plenty).
//
// Image: +sdcard=<file> loaded with $readmemh (byte per entry, @addr = byte
// offset). Without it the card reads as all zeros.
module SimSDCard #(
  parameter MEM_BYTES = 1048576
) (
  input  clock,
  input  reset,
  input  sck,
  input  cs,     // active low
  input  mosi,
  output miso
);

  reg [7:0] mem [0:MEM_BYTES-1];

  reg [8*1024-1:0] image;
  integer k;
  initial begin
    for (k = 0; k < MEM_BYTES; k = k + 1) mem[k] = 8'h00;
    if ($value$plusargs("sdcard=%s", image)) begin
      $display("[SimSDCard] loading %0s", image);
      $readmemh(image, mem);
    end else begin
      $display("[SimSDCard] no +sdcard=<hex>; card is blank");
    end
  end

  function [15:0] crc16_byte(input [15:0] c, input [7:0] d);
    integer i;
    reg [15:0] x;
    begin
      x = c;
      for (i = 7; i >= 0; i = i - 1)
        x = (x[15] ^ d[i]) ? ({x[14:0], 1'b0} ^ 16'h1021) : {x[14:0], 1'b0};
      crc16_byte = x;
    end
  endfunction

  function [7:0] rd(input [63:0] a);
    rd = (a < MEM_BYTES) ? mem[a[31:0]] : 8'h00;
  endfunction

  // ── bit level ──────────────────────────────────────────────────────────
  reg       sck_q;
  reg [31:0] since_rise;   // clock cycles since the last SCK rising edge
  reg [31:0] sck_period;   // last SCK period in clock cycles (logged per command)
  reg [2:0] bitcnt;
  reg [6:0] rx_sh;
  reg [7:0] tx_sh;
  reg [7:0] tx_next;
  reg       load_next;

  assign miso = cs ? 1'b1 : tx_sh[7];

  // ── byte level ─────────────────────────────────────────────────────────
  reg [2:0]  cmd_cnt;      // bytes of the current command received (0 = idle)
  reg [47:0] cmd;
  reg [7:0]  resp [0:4];
  reg [2:0]  resp_len, resp_idx;
  reg        idle_state, app_cmd;
  reg [3:0]  acmd41_polls;
  reg        stream;
  reg [2:0]  phase;        // 0 gap FF, 1 token FE, 2 data, 3 crc hi, 4 crc lo
  reg [63:0] addr;
  reg [9:0]  dcnt;
  reg [15:0] crc;

  // Decide what to send in the frame after the one that delivered `b`.
  task automatic on_byte(input [7:0] b);
    reg [47:0] c;
    reg [5:0]  idx;
    reg [31:0] arg;
    reg [7:0]  d;
    begin
      tx_next = 8'hFF;
      if (cmd_cnt == 0 && b[7:6] == 2'b01) begin
        cmd_cnt  = 1;
        cmd      = {40'd0, b};
        resp_len = 0;
        resp_idx = 0;
        stream   = 0;
      end else if (cmd_cnt != 0) begin
        c = {cmd[39:0], b};
        cmd = c;
        cmd_cnt = cmd_cnt + 1;
        if (cmd_cnt == 6) begin
          cmd_cnt = 0;
          idx = c[45:40];
          arg = c[39:8];
          $display("[SimSDCard] %0s%0d arg=0x%08x sck_period=%0d cycles", app_cmd ? "ACMD" : "CMD", idx, arg, sck_period);
          $fflush;
          resp_idx = 0;
          resp_len = 1;
          resp[0]  = 8'h04;
          if (app_cmd && idx == 41) begin
            // One "still idle" answer first, so the host's poll loop runs.
            resp[0] = (acmd41_polls == 0) ? 8'h01 : 8'h00;
            if (acmd41_polls != 0) idle_state = 0;
            acmd41_polls = acmd41_polls + 1;
            app_cmd = 0;
          end else begin
            app_cmd = 0;
            case (idx)
              0:  begin idle_state = 1; acmd41_polls = 0; resp[0] = 8'h01; end
              8:  begin resp_len = 5; resp[0] = {7'd0, idle_state}; resp[1] = 8'h00;
                        resp[2] = 8'h00; resp[3] = {4'd0, arg[11:8]}; resp[4] = arg[7:0]; end
              55: begin app_cmd = 1; resp[0] = {7'd0, idle_state}; end
              58: begin resp_len = 5; resp[0] = {7'd0, idle_state}; resp[1] = 8'hC0;  // powered up, CCS = 1
                        resp[2] = 8'hFF; resp[3] = 8'h80; resp[4] = 8'h00; end
              16: resp[0] = {7'd0, idle_state};
              12: begin resp_len = 2; resp[0] = 8'hFF; resp[1] = 8'h00; end  // stuff byte, R1
              18: begin resp[0] = {7'd0, idle_state}; stream = 1; phase = 0;
                        addr = {32'd0, arg} << 9; end
              default: ;
            endcase
          end
          tx_next = resp[0];
          resp_idx = 1;
        end
      end else if (resp_idx < resp_len) begin
        tx_next = resp[resp_idx];
        resp_idx = resp_idx + 1;
      end else if (stream) begin
        case (phase)
          0: begin tx_next = 8'hFF; phase = 1; end
          1: begin tx_next = 8'hFE; phase = 2; dcnt = 0; crc = 16'h0000; end
          2: begin
               d = rd(addr);
               tx_next = d;
               crc = crc16_byte(crc, d);
               addr = addr + 1;
               if (dcnt == 511) phase = 3;
               dcnt = dcnt + 1;
             end
          3: begin tx_next = crc[15:8]; phase = 4; end
          default: begin tx_next = crc[7:0]; phase = 0; end
        endcase
      end
    end
  endtask

  always @(posedge clock) begin
    sck_q <= sck;
    if (sck && !sck_q) begin
      sck_period <= since_rise + 1;
      since_rise <= 0;
    end else begin
      since_rise <= since_rise + 1;
    end
    if (reset) begin
      bitcnt <= 0; tx_sh <= 8'hFF; load_next <= 0;
      cmd_cnt = 0; resp_len = 0; resp_idx = 0; stream = 0;
      idle_state = 1; app_cmd = 0; acmd41_polls = 0;
    end else if (cs) begin
      // Deselected: drop any half byte, response or block stream.
      bitcnt <= 0; tx_sh <= 8'hFF; load_next <= 0;
      cmd_cnt = 0; resp_len = 0; resp_idx = 0; stream = 0;
    end else begin
      if (sck && !sck_q) begin                 // rising edge: sample MOSI
        rx_sh  <= {rx_sh[5:0], mosi};
        bitcnt <= bitcnt + 1;
        if (bitcnt == 7) begin
          on_byte({rx_sh, mosi});
          load_next <= 1;
        end
      end else if (!sck && sck_q) begin        // falling edge: next MISO bit
        if (load_next) begin
          tx_sh <= tx_next;
          load_next <= 0;
        end else begin
          tx_sh <= {tx_sh[6:0], 1'b1};
        end
      end
    end
  end

endmodule
