`timescale 1ns/1ps
module mic_sampler #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer SAMPLE_DIV = 12500
)(
    input wire clk,
    input wire rst,
    input wire enable,
    output wire mic_sclk,
    output reg mic_ncs,
    input wire mic_sdata,
    output reg [7:0] sample_data,
    output reg sample_valid,
    output reg [11:0] sample_data_12
);
    reg [2:0] spi_clk_cnt;
    wire spi_clk_rising = (spi_clk_cnt == 3'd3);
    wire spi_clk_falling = (spi_clk_cnt == 3'd7);
    always @(posedge clk) begin
        if (rst)
            spi_clk_cnt <= 3'd0;
        else
            spi_clk_cnt <= spi_clk_cnt + 3'd1;
    end
    assign mic_sclk = mic_ncs ? 1'b1 : ~spi_clk_cnt[2];
    reg [$clog2(SAMPLE_DIV)-1:0] rate_cnt;
    reg sample_trigger;
    always @(posedge clk) begin
        if (rst || !enable) begin
            rate_cnt <= 0;
            sample_trigger <= 1'b0;
        end else begin
            sample_trigger <= 1'b0;
            if (rate_cnt >= SAMPLE_DIV - 1) begin
                rate_cnt <= 0;
                sample_trigger <= 1'b1;
            end else begin
                rate_cnt <= rate_cnt + 1;
            end
        end
    end
    localparam S_IDLE = 2'd0,
               S_ACQUIRE = 2'd1,
               S_DONE = 2'd2;
    reg [1:0] spi_state;
    reg [4:0] bit_cnt;
    reg [15:0] shift_reg;
    always @(posedge clk) begin
        if (rst) begin
            spi_state <= S_IDLE;
            mic_ncs <= 1'b1;
            bit_cnt <= 5'd0;
            shift_reg <= 16'd0;
            sample_data <= 8'd128;
            sample_valid <= 1'b0;
            sample_data_12 <= 12'd0;
        end else begin
            sample_valid <= 1'b0;
            case (spi_state)
                S_IDLE: begin
                    mic_ncs <= 1'b1;
                    if (sample_trigger && enable) begin
                        mic_ncs <= 1'b0;
                        bit_cnt <= 5'd0;
                        shift_reg <= 16'd0;
                        spi_state <= S_ACQUIRE;
                    end
                end
                S_ACQUIRE: begin
                    if (spi_clk_rising) begin
                        shift_reg <= {shift_reg[14:0], mic_sdata};
                        bit_cnt <= bit_cnt + 5'd1;
                        if (bit_cnt == 5'd15) begin
                            spi_state <= S_DONE;
                        end
                    end
                end
                S_DONE: begin
                    mic_ncs <= 1'b1;
                    sample_data_12 <= shift_reg[11:0];
                    sample_data <= shift_reg[11:4];
                    sample_valid <= 1'b1;
                    spi_state <= S_IDLE;
                end
                default: spi_state <= S_IDLE;
            endcase
        end
    end
endmodule
