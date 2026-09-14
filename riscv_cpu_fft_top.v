`timescale 1ns/1ps

module riscv_fft_top #(
    parameter integer FFT_LEN = 64,
    parameter integer IMEM_WORDS = 8192,
    parameter integer DMEM_WORDS = 2048,
    parameter integer MIC_SAMPLE_DIV = 12500
)(
    input wire clk,
    input wire btnC,
    input wire [15:0] sw,
    output wire [15:0] led,
    output wire [6:0] seg,
    output wire dp,
    output wire [3:0] an,
    input wire uart_rx,
    output wire uart_tx,

    //pmod mic
    output wire JA_0,
    input wire JA_2,
    output wire JA_3
);

    wire rst = btnC;

    //UART
    wire raw_rx_ready;
    wire [7:0] raw_rx_data;
    wire raw_rx_ack;

    wire uart_tx_wr;
    wire [7:0] uart_tx_data;
    wire uart_tx_busy;

    uart_rx #(.CLK_HZ(100_000_000), .BAUD(115200)) u_rx(
        .clk(clk),
        .rst(rst),
        .rx(uart_rx),
        .data(raw_rx_data),
        .ready(raw_rx_ready),
        .ack(raw_rx_ack)
    );

    uart_tx #(.CLK_HZ(100_000_000), .BAUD(115200)) u_tx(
        .clk(clk),
        .rst(rst),
        .tx(uart_tx),
        .data(uart_tx_data),
        .wr(uart_tx_wr),
        .busy(uart_tx_busy)
    );

    wire [7:0] cpu_rx_data;
    wire cpu_rx_ready;
    wire cpu_rx_ack;

    wire [7:0] uart_fft_rx_data; //UART bytes that go directly to FFT
    wire uart_fft_rx_valid;

    wire fft_restart;

    wire [1:0] router_mode;
    wire [7:0] router_hdr_byte0;
    wire [7:0] router_hdr_num_fft;
    wire router_cpu_release;
    wire mic_enable;
    wire fft_src_mic;
    wire fft_frame_done_bram;

    uart_router u_router(
        .clk(clk),
        .rst(rst),
        //Raw UART RX
        .raw_rx_data(raw_rx_data),
        .raw_rx_ready(raw_rx_ready),
        .raw_rx_ack(raw_rx_ack),
        //CPU RX
        .cpu_rx_data(cpu_rx_data),
        .cpu_rx_ready(cpu_rx_ready),
        .cpu_rx_ack(cpu_rx_ack),
        //FFT RX (UART source)
        .fft_rx_data(uart_fft_rx_data),
        .fft_rx_valid(uart_fft_rx_valid),
        //FFT frame done counter
        .fft_frame_done(fft_frame_done_bram),
        //FFT stream manager restart
        .fft_restart(fft_restart),
        //Status
        .mode(router_mode),
        .hdr_byte0(router_hdr_byte0),
        .hdr_num_fft(router_hdr_num_fft),
        //CPU control
        .cpu_release(router_cpu_release),
        //PMOD MIC mode
        .mic_enable(mic_enable),
        .fft_src_mic(fft_src_mic)
    );

    //PMOD Sampler
    wire mic_sclk;
    wire mic_ncs;
    wire mic_sdata = JA_2;

    wire [7:0] mic_sample_data;
    wire mic_sample_valid;
    wire [11:0] mic_sample_12;

    assign JA_0 = mic_ncs;
    assign JA_3 = mic_sclk;

    mic_sampler #(.CLK_HZ(100_000_000), .SAMPLE_DIV(MIC_SAMPLE_DIV)) u_mic(
        .clk(clk),
        .rst(rst),
        .enable(mic_enable),
        //SPI pins
        .mic_sclk(mic_sclk),
        .mic_ncs(mic_ncs),
        .mic_sdata(mic_sdata),
        //sample output
        .sample_data(mic_sample_data),
        .sample_valid(mic_sample_valid),
        .sample_data_12(mic_sample_12)
    );

    //mux that controls input into fft, either from uart or plod mic
    wire [7:0] fft_rx_data = fft_src_mic ? mic_sample_data : uart_fft_rx_data;
    wire fft_rx_valid = fft_src_mic ? mic_sample_valid : uart_fft_rx_valid;

    //fft stream manager that handles paths to fft and its output (axi4 protocol)
    wire [31:0] s_axis_data_tdata;
    wire s_axis_data_tvalid;
    wire s_axis_data_tlast;
    wire s_axis_data_tready;
    wire [7:0] s_axis_config_tdata;
    wire s_axis_config_tvalid;
    wire s_axis_config_tready;
    wire [31:0] m_axis_data_tdata;
    wire m_axis_data_tvalid;
    wire m_axis_data_tlast;
    wire m_axis_data_tready;

    wire [$clog2(FFT_LEN)-1:0] bram_wr_addr;
    wire [47:0] bram_wr_data;
    wire bram_wr_en;
    wire bram_wr_frame_done;

    fft_stream_manager #(
        .FFT_LEN(FFT_LEN),
        .DATA_W(8),
        .FFT_DW(16),
        .OUT_W(16)
    ) u_fft_mgr(
        .clk(clk),
        .rst(rst),
        .fft_rx_data(fft_rx_data),
        .fft_rx_valid(fft_rx_valid),
        // Session restart
        .restart(fft_restart),
        //axi4 to fft
        .s_axis_data_tdata(s_axis_data_tdata),
        .s_axis_data_tvalid(s_axis_data_tvalid),
        .s_axis_data_tlast(s_axis_data_tlast),
        .s_axis_data_tready(s_axis_data_tready),
        .s_axis_config_tdata(s_axis_config_tdata),
        .s_axis_config_tvalid(s_axis_config_tvalid),
        .s_axis_config_tready(s_axis_config_tready),
        //fft to axi4
        .m_axis_data_tdata(m_axis_data_tdata),
        .m_axis_data_tvalid(m_axis_data_tvalid),
        .m_axis_data_tlast(m_axis_data_tlast),
        .m_axis_data_tready(m_axis_data_tready),
        //BRAM write
        .bram_wr_addr(bram_wr_addr),
        .bram_wr_data(bram_wr_data),
        .bram_wr_en(bram_wr_en),
        .bram_wr_frame_done(bram_wr_frame_done),
        //unused now
        .collecting(),
        .processing()
    );

    //FFT IP
    xfft_0 u_fft(
        .aclk(clk),
        .s_axis_data_tdata(s_axis_data_tdata),
        .s_axis_data_tvalid(s_axis_data_tvalid),
        .s_axis_data_tlast(s_axis_data_tlast),
        .s_axis_data_tready(s_axis_data_tready),
        .s_axis_config_tdata(s_axis_config_tdata),
        .s_axis_config_tvalid(s_axis_config_tvalid),
        .s_axis_config_tready(s_axis_config_tready),
        .m_axis_data_tdata(m_axis_data_tdata),
        .m_axis_data_tvalid(m_axis_data_tvalid),
        .m_axis_data_tlast(m_axis_data_tlast),
        .m_axis_data_tready(m_axis_data_tready)
    );

    //ping pong bram
    wire [$clog2(FFT_LEN)-1:0] fft_bram_rd_addr;
    wire [47:0] fft_bram_rd_data;
    wire fft_frame_ready;
    wire fft_frame_ack;

    assign fft_frame_done_bram = bram_wr_frame_done;

    fft_pingpong_bram #(
        .FFT_LEN(FFT_LEN),
        .DATA_W(48)
    ) u_bram(
        .clk(clk),
        .rst(rst),
        .wr_addr(bram_wr_addr),
        .wr_data(bram_wr_data),
        .wr_en(bram_wr_en),
        .wr_frame_done(bram_wr_frame_done),
        .rd_addr(fft_bram_rd_addr),
        .rd_data(fft_bram_rd_data),
        .rd_frame_ready(fft_frame_ready),
        .rd_frame_ack(fft_frame_ack),
        .write_bank(),
        .read_bank()
    );

    //CPU
    wire [31:0] dbg_pc;
    wire [31:0] dbg_x10;

    riscv_core_pipelined #(
        .IMEM_WORDS(IMEM_WORDS),
        .DMEM_WORDS(DMEM_WORDS)
    ) u_cpu(
        .clk(clk),
        .rst(rst),
        .led_out(led),
        .dbg_pc(dbg_pc),
        .dbg_x10(dbg_x10),
        .uart_rx_ready(cpu_rx_ready),
        .uart_rx_data(cpu_rx_data),
        .uart_rx_ack(cpu_rx_ack),
        .uart_tx_wr(uart_tx_wr),
        .uart_tx_data(uart_tx_data),
        .uart_tx_busy(uart_tx_busy),
        .seg_override_val(),
        .seg_override_mode(),
        .router_mode(router_mode),
        .router_hdr_byte0(router_hdr_byte0),
        .router_hdr_num_fft(router_hdr_num_fft),
        .router_cpu_release(router_cpu_release),
        .fft_bram_rd_addr(fft_bram_rd_addr),
        .fft_bram_rd_data(fft_bram_rd_data),
        .fft_frame_ready(fft_frame_ready),
        .fft_frame_ack(fft_frame_ack)
    );

    //sevseg
    wire [15:0] disp_val = sw[0] ? dbg_x10[15:0] : dbg_pc[15:0];

    sevenseg_hex4 u_ss(
        .clk(clk),
        .rst(rst),
        .value(disp_val),
        .seg(seg),
        .dp(dp),
        .an(an)
    );

endmodule

module uart_rx #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD = 115200
)(
    input wire clk,
    input wire rst,
    input wire rx,
    output reg [7:0] data,
    output reg ready,
    input wire ack
);
    localparam integer CLK_PER_BIT = CLK_HZ / BAUD;
    localparam integer HALF_BIT = CLK_PER_BIT / 2;

    reg rx_s0, rx_s1;
    always @(posedge clk) begin rx_s0 <= rx; rx_s1 <= rx_s0; end

    localparam ST_IDLE = 2'd0, ST_START = 2'd1, ST_DATA = 2'd2, ST_STOP = 2'd3;

    reg [1:0] state;
    reg [31:0] cnt;
    reg [3:0] bit_idx;
    reg [7:0] shift;

    always @(posedge clk) begin
        if(rst) begin
            state <= ST_IDLE; cnt <= 0; bit_idx <= 0;
            shift <= 0; data <= 0; ready <= 0;
        end else begin
            if(ack) ready <= 1'b0;
            case(state)
                ST_IDLE: begin
                    if(!rx_s1) begin
                        cnt <= 0; state <= ST_START;
                    end
                end
                ST_START: begin
                    if(cnt == HALF_BIT-1) begin
                        cnt <= 0; state <= ST_DATA; bit_idx <= 0;
                    end else 
                        cnt <= cnt + 1;
                end
                ST_DATA: begin
                    if(cnt == CLK_PER_BIT-1) begin
                        cnt <= 0; shift[bit_idx] <= rx_s1;
                        if(bit_idx == 7)
                            state <= ST_STOP;
                        else 
                            bit_idx <= bit_idx + 1;
                    end else 
                        cnt <= cnt + 1;
                end
                ST_STOP: begin
                    if(cnt == CLK_PER_BIT-1) begin
                        cnt <= 0;
                        if(rx_s1) begin 
                            data <= shift; 
                            ready <= 1'b1; 
                        end
                        state <= ST_IDLE;
                    end else
                        cnt <= cnt + 1;
                end
            endcase
        end
    end
endmodule


module uart_tx #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD = 115200
)(
    input wire clk,
    input wire rst,
    output reg tx,
    input wire [7:0] data,
    input wire wr,
    output reg busy
);
    localparam integer CLK_PER_BIT = CLK_HZ / BAUD;

    reg [31:0] cnt;
    reg [3:0] bit_idx;
    reg [9:0] shift;

    localparam ST_IDLE = 1'b0, ST_SEND = 1'b1;
    reg state;

    always @(posedge clk) begin
        if(rst) begin
            tx <= 1'b1; busy <= 1'b0; state <= ST_IDLE; cnt <= 0;
        end else begin
            case(state)
                ST_IDLE: begin
                    tx <= 1'b1;
                    if(wr && !busy) begin
                        shift <= {1'b1, data, 1'b0};
                        cnt <= 0; bit_idx <= 0; busy <= 1'b1; state <= ST_SEND;
                    end
                end
                ST_SEND: begin
                    tx <= shift[0];
                    if(cnt == CLK_PER_BIT-1) begin
                        cnt <= 0; shift <= {1'b1, shift[9:1]};
                        if(bit_idx == 9) begin
                            busy <= 1'b0; state <= ST_IDLE;
                        end
                        else bit_idx <= bit_idx + 1;
                    end else cnt <= cnt + 1;
                end
            endcase
        end
    end
endmodule

module sevenseg_hex4(
    input wire clk,
    input wire rst,
    input wire [15:0] value,
    output reg [6:0] seg,
    output reg dp,
    output reg [3:0] an
);
    reg [15:0] refresh;
    always @(posedge clk) begin
        if(rst)
            refresh <= 16'b0;
        else refresh <= refresh + 1'b1;
    end

    wire [1:0] sel = refresh[15:14];

    reg [3:0] nibble;
    always @(*) begin
        dp = 1'b1;
        case(sel)
            2'd0: begin 
                an = 4'b1110;
                nibble = value[3:0];
            end
            2'd1: begin
                an = 4'b1101;
                nibble = value[7:4];
            end
            2'd2: begin
                an = 4'b1011;
                nibble = value[11:8];
            end
            2'd3: begin
                an = 4'b0111;
                nibble = value[15:12];
            end
        endcase
        case(nibble)
            4'h0: seg = 7'b1000000;
            4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;
            4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;
            4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;
            4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0010000;
            4'hA: seg = 7'b0001000;
            4'hB: seg = 7'b0000011;
            4'hC: seg = 7'b1000110;
            4'hD: seg = 7'b0100001;
            4'hE: seg = 7'b0000110;
            4'hF: seg = 7'b0001110;
        endcase
    end
endmodule