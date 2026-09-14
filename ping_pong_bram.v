module fft_pingpong_bram #(
    parameter FFT_LEN = 64,
    parameter DATA_W = 48
)(
    input wire clk,
    input wire rst,

    //writing side for fft output
    input wire [$clog2(FFT_LEN)-1:0] wr_addr,
    input wire [DATA_W-1:0] wr_data,
    input wire wr_en,
    input wire wr_frame_done,

    //reading side
    input wire [$clog2(FFT_LEN)-1:0] rd_addr,
    output reg [DATA_W-1:0] rd_data,
    output reg rd_frame_ready,
    input wire rd_frame_ack, //consumer done reading

    //debug (0=ping, 1=pong)
    output wire write_bank,
    output wire read_bank
);

    //two bram banks that we will be switching between
    reg [DATA_W-1:0] bram_ping [0:FFT_LEN-1];
    reg [DATA_W-1:0] bram_pong [0:FFT_LEN-1];

    //Bank select register that determines who the writer is and who the reader is
    //writer is ping when bank_sel = 0, else pong and reader is always inverse of writer
    reg bank_sel; //flips on each wr_frame_done

    assign write_bank = bank_sel;
    assign read_bank = ~bank_sel;

    //write side
    always @(posedge clk) begin
        if(wr_en) begin
            if(bank_sel == 1'b0)
                bram_ping[wr_addr] <= wr_data;
            else
                bram_pong[wr_addr] <= wr_data;
        end
    end

    //read side
    //opposite of write side
    always @(posedge clk) begin
        if(bank_sel == 1'b1)
            rd_data <= bram_ping[rd_addr];
        else
            rd_data <= bram_pong[rd_addr];
    end

   always @(posedge clk) begin
    if(rst) begin
        bank_sel <= 1'b0;
        rd_frame_ready <= 1'b0;
    end else begin
        if(rd_frame_ack) begin
            rd_frame_ready <= 1'b0;
        end else if(wr_frame_done && !rd_frame_ready) begin
            bank_sel <= ~bank_sel;
            rd_frame_ready <= 1'b1;
        end else if(wr_frame_done && rd_frame_ready) begin
            //Frame completed while consumer still reading...just swap banks anyways
            bank_sel <= ~bank_sel;
        end
    end
end
endmodule