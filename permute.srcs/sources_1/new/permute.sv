`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01/31/2019 02:18:18 PM
// Design Name: 
// Module Name: permute
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

`define READ  0
`define WRITE 1
`define WAIT  2

module permute#(
parameter
	ROW        = 32,
	COLUMN     = 128,
	DATA_WIDTH = 27,
	DATA_WIDTH_AXI = 32
)(
	// row-side vec in
	input  [ROW*DATA_WIDTH_AXI-1:0] row_in_tdata,
	input  row_in_tvalid,
	output row_in_tready,
	input  row_in_tlast,
	// row-side vec out
	output [ROW*DATA_WIDTH_AXI-1:0] row_out_tdata,
	output row_out_tvalid,
	input  row_out_tready,
	output row_out_tlast,
	// mem-side add in
	input  [31:0] mem_add_in_tdata,
	input  mem_add_in_tvalid,
	output mem_add_in_tready,
	// memory interface
	output mem_int_clk,
	output [31:0]                  mem_int_add,
	output [COLUMN*DATA_WIDTH-1:0] mem_int_din,
	input  [COLUMN*DATA_WIDTH-1:0] mem_int_dout,
	output mem_int_we,
	output mem_int_en,
	// control port
	input  [3:0] mode,
	// mode: 0: axi->mem, row->column
	//       1: mem->axi, column->row
	//       8: axi->mem, column->column with block size 32
	//       9: axi->mem, column->column with block size 25
	//      10: axi->mem, column->column with block size 21
	//      11: axi->mem, column->column with block size 16
	//      12: axi->mem, column->column with block size 12
	output done,
	input  srst,
	input  clk,
	input  rst_n
);

reg  column_div;
reg  column_block;

reg  [1:0] state;
reg  counter;
wire read_incr;
wire write_incr;
wire [1:0] state_r;
wire counter_r;
wire read_incr_r;

wire [31:0] read_size;
wire [31:0] write_size;
wire din_valid;
wire dout_ready;

reg  [DATA_WIDTH-1:0] regheap [ROW-1:0][COLUMN-1:0];

integer i, j;
genvar g, k;

// state machine
always_comb begin
	case (mode)
		8 : column_div = 4;
		9 : column_div = 5;
		10: column_div = 6;
		11: column_div = 8;
		12: column_div = 10;
		default: column_div = 0;
	endcase
	case (mode)
		8 : column_block = 32;
		9 : column_block = 25;
		10: column_block = 21;
		11: column_block = 16;
		12: column_block = 12;
		default: column_div = 0;
	endcase
end

assign read_incr = (state == `READ) && (
	((mode == 0) && row_in_tvalid)
	|| ((mode == 1) && mem_add_in_tvalid)
	|| ((mode >= 8) && (mode <= 12) && row_in_tvalid));
assign write_incr = (state == `WRITE)  && (
	((mode == 0) && mem_add_in_tvalid)
	|| ((mode == 1) && (row_out_tready)));

always @(posedge clk or negedge rst_n) begin
	if (~rst_n) begin
		counter <= 0;
		state <= `READ;
	end else if (srst) begin
		counter <= 0;
		state <= `READ;
	end else begin
		if (mode == 0) begin //axi->mem, row->column
			if (state == `READ) begin
				if(read_incr) begin
					counter <= counter + 1; //keep track of the number of blocks we calculated
					if (counter >= COLUMN-1) begin //we finished all the blocks
						counter <= 0;
						state <= `WRITE; //start write out
					end
				end
			end else if (state == `WRITE) begin 
				if(write_incr) begin
					counter <= counter + 1;
					if (counter >= ROW-1) begin
						counter <= 0;   //after we finish, goes back to read
						state <= `READ;
					end
				end
			end else begin // abnormal, reset
				counter <= 0;  
				state <= `READ;
			end
		end else if (mode == 1) begin // mem->axi, column->row
			if (state == `READ) begin
				if(read_incr) begin
					counter <= counter + 1; //keep track of the number of blocks we calculated
					if (counter >= ROW-1) begin //we finished all the blocks
						counter <= 0;
						state <= `WAIT; //start write out
					end
				end
			end else if (state == `WAIT) begin 
				counter <= counter + 1;
				if (counter >= 2) begin
					counter <= 0;   //after we finish, goes back to read
					state <= `WRITE;
				end
			end else if (state == `WRITE) begin //state==write
				if(write_incr) begin
					counter <= counter + 1;
					if (counter >= COLUMN-1) begin
						counter <= 0;   //after we finish, goes back to read
						state <= `READ;
					end
				end
			end else begin // abnormal, reset
				counter <= 0;  
				state <= `READ;
			end
		end else if ((mode >= 8) && (mode <= 12)) begin // axi->mem, column->column
			if (state == `READ) begin
				if(read_incr) begin
					counter <= counter + 1;//keep track of the number of blocks we calculated
					if (counter >= column_div-1) begin//we finished all the blocks
						counter <= 0;
					end
				end
			end else begin // abnormal, reset
				counter <= 0;  
				state <= `READ;
			end
		end  
	end 
end

// memory interface
assign mem_add_in_tready = ((state == `READ) && (mode == 1)) 
	|| ((state == `WRITE) && (mode == 0))
	|| ((state == `WRITE) && (mode >= 8) && (mode <= 12));
assign mem_int_add = mem_add_in_tdata;
assign mem_int_en  = 1;
assign mem_int_we  = ((state == `WRITE) && (mode == 0))
	|| ((state == `WRITE) && (mode >= 8) && (mode <= 12));
for (g = 0; g < COLUMN; g = g + 1) begin
	assign mem_int_din[(g+1)*DATA_WIDTH-1:g*DATA_WIDTH] = regheap[0][g];
end

// read from axi-stream
assign row_in_tready = ((state == `READ) && (mode == 1))
	|| ((state == `READ) && (mode >= 8) && (mode <= 12)); 

// write to axi-stream
for (g = 0; g < ROW; g = g + 1) begin
	assign row_out_tdata[(i+1)*DATA_WIDTH_AXI-1:(i+1)*DATA_WIDTH_AXI-DATA_WIDTH] = regheap[i][0];
	assign row_out_tdata[(i+1)*DATA_WIDTH_AXI-DATA_WIDTH:i*DATA_WIDTH_AXI] = 0;
end
assign row_out_tvalid = (mode == 1) & (state == `WRITE);
assign row_out_tlast  = 1;

// write to regheap
always @(posedge clk) begin : proc_regheap
	if (srst) begin
		for (i = 0; i < ROW; i = i + 1) begin
			for (j = 0; j < COLUMN; j = j + 1) begin
				regheap[i][j] <= 0;
			end
		end
	end else begin
		if (mode == 0) begin //axi->mem, row->column
			if ((state == `READ) && read_incr) begin
				for (i = 0; i < ROW; i = i + 1) begin
					regheap[i][COLUMN-1] <= row_in_tdata[(i+1)*DATA_WIDTH_AXI-1:(i+1)*DATA_WIDTH_AXI-DATA_WIDTH];
					for (g = 0; g < COLUMN-1; g = g + 1) begin
						regheap[i][g] <= regheap[i][g+1];
					end
				end
			end else if ((state == `WRITE) && write_incr) begin
				for (g = 0; g < COLUMN; g = g + 1) begin
					regheap[ROW-1][g] <= 0;
					for (i = 0; i < ROW-1; i = i + 1) begin
						regheap[i][g] <= regheap[i+1][g];
					end
				end
			end
		end else if (mode == 1) begin // mem->axi, column->row
			if ((state_r == `READ) & read_incr_r) begin
				for (j = 0; j < COLUMN; j = j + 1) begin
					regheap[ROW-1][j] <= mem_int_dout[(j+1)*DATA_WIDTH-1:j*DATA_WIDTH];
					for (i = 0; i < ROW-1; i = i + 1) begin
						regheap[i][g] <= regheap[i+1][g];
					end
				end
			end else if ((state == `WRITE) && write_incr) begin
				for (i = 0; i < ROW; i = i + 1) begin
					regheap[i][COLUMN-1] <= 0;
					for (g = 0; g < COLUMN-1; g = g + 1) begin
						regheap[i][g] <= regheap[i][g+1];
					end
				end
			end
		end else if ((mode >= 8) && (mode <= 12)) begin //axi->mem, column->column
			if ((state_r == `READ) & read_incr) begin
				for (j = 0; j < column_block; j = j + 1) begin
					regheap[0][counter * column_block + j] <= row_in_tdata[(j+1)*DATA_WIDTH-1:j*DATA_WIDTH];
				end
			end
		end
	end
end

endmodule
