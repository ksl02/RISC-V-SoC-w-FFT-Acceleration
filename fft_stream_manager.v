module fft_stream_manager #(
    parameter FFT_LEN = 64,
    parameter DATA_W = 8,
    parameter FFT_DW = 16,
    parameter OUT_W = 16
)(
    input wire clk,
    input wire rst,

    input wire [DATA_W-1:0] fft_rx_data,
    input wire fft_rx_valid, //single-cycle

    input wire restart,

    //axi stream input to fft ip
    output reg [31:0] s_axis_data_tdata,
    output reg s_axis_data_tvalid,
    output reg s_axis_data_tlast,
    input wire s_axis_data_tready,

    //axi4 stream config
    output reg [7:0] s_axis_config_tdata,
    output reg s_axis_config_tvalid,
    input wire s_axis_config_tready,

    //fft ip axi4 stream output
    input wire [31:0] m_axis_data_tdata,
    input wire m_axis_data_tvalid,
    input wire m_axis_data_tlast,
    output wire m_axis_data_tready,

    output reg [$clog2(FFT_LEN)-1:0] bram_wr_addr,
    output reg [47:0] bram_wr_data, //{q, i} 24 bit each
    output reg bram_wr_en,
    output reg bram_wr_frame_done, //1-clk pulse

    output wire collecting,
    output wire processing
);

    localparam ADDR_W = $clog2(FFT_LEN);

    //states, whether or not we are configuring at startup, waiting for len samples, sending samples to the fft core, or sending fft output to bram
    localparam S_CONFIG = 2'd0,
               S_COLLECT = 2'd1,
               S_FEED = 2'd2,
               S_CAPTURE = 2'd3;

    reg [1:0] state;

    reg [ADDR_W-1:0] samp_wr_ptr;
    reg [ADDR_W-1:0] samp_rd_ptr;
    reg [ADDR_W-1:0] cap_ptr;

    reg [DATA_W-1:0] sample_buf [0:FFT_LEN-1];

    assign collecting = (state == S_COLLECT);
    assign processing = (state == S_FEED || state == S_CAPTURE);

    //accept FFT output only while in capturing state (sending fft output to bram)
    assign m_axis_data_tready = (state == S_CAPTURE);

    //u8 to signed centered 16bit conversion
    function [15:0] u8_to_s16_centered;
        input [7:0] x;
        reg signed [8:0] tmp;
        begin
            tmp = $signed({1'b0, x}) - 9'sd128;
            u8_to_s16_centered = {{7{tmp[8]}}, tmp};
        end
    endfunction

    always @(posedge clk) begin
        if(rst) begin
            state <= S_CONFIG;
            samp_wr_ptr <= {ADDR_W{1'b0}};
            samp_rd_ptr <= {ADDR_W{1'b0}};
            cap_ptr <= {ADDR_W{1'b0}};
            s_axis_data_tdata <= 32'd0;
            s_axis_data_tvalid <= 1'b0;
            s_axis_data_tlast <= 1'b0;
            s_axis_config_tdata <= 8'h00;
            s_axis_config_tvalid <= 1'b0;
            bram_wr_en <= 1'b0;
            bram_wr_addr <= {ADDR_W{1'b0}};
            bram_wr_data <= 48'd0;
            bram_wr_frame_done <= 1'b0;
        end else begin
            // Default single-cycle pulses
            bram_wr_en <= 1'b0;
            bram_wr_frame_done <= 1'b0;

            //Session restart from router entering FFT_MODE
            if(restart && state != S_CONFIG) begin
                state <= S_COLLECT;
                samp_wr_ptr <= {ADDR_W{1'b0}};
                samp_rd_ptr <= {ADDR_W{1'b0}};
                cap_ptr <= {ADDR_W{1'b0}};
                s_axis_data_tvalid <= 1'b0;
                s_axis_data_tlast <= 1'b0;
            end else begin
                case(state)
                    //send fft config to IP core
                    S_CONFIG: begin
                        s_axis_data_tvalid <= 1'b0;
                        s_axis_data_tlast <= 1'b0;
                        s_axis_config_tdata <= 8'h00; //forward FFT
                        s_axis_config_tvalid <= 1'b1;
                        if(s_axis_config_tready) begin
                            s_axis_config_tvalid <= 1'b0;
                            samp_wr_ptr <= {ADDR_W{1'b0}};
                            samp_rd_ptr <= {ADDR_W{1'b0}};
                            cap_ptr <= {ADDR_W{1'b0}};
                            state <= S_COLLECT;
                        end
                    end

                    //wait for FFT_LEN samples
                    S_COLLECT: begin
                        s_axis_data_tvalid <= 1'b0;
                        s_axis_data_tlast <= 1'b0;
                        if(fft_rx_valid) begin
                            sample_buf[samp_wr_ptr] <= fft_rx_data;
                            if(samp_wr_ptr == FFT_LEN - 1) begin
                                samp_wr_ptr <= {ADDR_W{1'b0}};
                                samp_rd_ptr <= {ADDR_W{1'b0}};
                                state <= S_FEED;
                            end else begin
                                samp_wr_ptr <= samp_wr_ptr + 1'b1;
                            end
                        end
                    end

                    //stream samples out of fft IP core
                    S_FEED: begin
                        if (!s_axis_data_tvalid) begin
                            s_axis_data_tdata <= {16'd0,
                                u8_to_s16_centered(sample_buf[samp_rd_ptr])};
                            s_axis_data_tvalid <= 1'b1;
                            s_axis_data_tlast <= (samp_rd_ptr == FFT_LEN - 1);
                        end else if (s_axis_data_tready) begin
                            if (samp_rd_ptr == FFT_LEN - 1) begin
                                s_axis_data_tvalid <= 1'b0;
                                s_axis_data_tlast <= 1'b0;
                                samp_rd_ptr <= {ADDR_W{1'b0}};
                                cap_ptr <= {ADDR_W{1'b0}};
                                state <= S_CAPTURE;
                            end else begin
                                samp_rd_ptr <= samp_rd_ptr + 1'b1;
                                s_axis_data_tdata <= {16'd0, u8_to_s16_centered(sample_buf[samp_rd_ptr + 1'b1])};
                                s_axis_data_tvalid <= 1'b1;
                                s_axis_data_tlast <= ((samp_rd_ptr + 1'b1) == FFT_LEN - 1);
                            end
                        end
                    end

                    //send fft output to bram
                    S_CAPTURE: begin
                        s_axis_data_tvalid <= 1'b0;
                        s_axis_data_tlast <= 1'b0;
                        if(m_axis_data_tvalid && m_axis_data_tready) begin
                            bram_wr_addr <= cap_ptr;
                            //sign extend 16-bit FFT outputs to 24-bit
                            //q,i format
                            bram_wr_data <= {{{8{m_axis_data_tdata[31]}},m_axis_data_tdata[31:16]}, {{8{m_axis_data_tdata[15]}}, m_axis_data_tdata[15:0]}};
                            bram_wr_en <= 1'b1;
                            if(m_axis_data_tlast) begin
                                bram_wr_frame_done <= 1'b1;
                                cap_ptr <= {ADDR_W{1'b0}};
                                samp_wr_ptr <= {ADDR_W{1'b0}};
                                state <= S_COLLECT; //switch to collect state if we're done
                            end else begin
                                cap_ptr <= cap_ptr + 1'b1;
                            end
                        end
                    end
                    default:
                        state <= S_CONFIG;
                endcase
            end
        end
    end
endmodule