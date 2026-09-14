module uart_router (
    input wire clk,
    input wire rst,
    //raw uart data on rx side
    input wire [7:0] raw_rx_data,
    input wire raw_rx_ready,
    output reg raw_rx_ack,

    //rx data to CPU
    output reg [7:0] cpu_rx_data,
    output reg cpu_rx_ready,
    input wire cpu_rx_ack,

    //UART RX to FFT core
    output reg [7:0] fft_rx_data,
    output reg fft_rx_valid,

    //fft frame done from ping pong buff
    input wire fft_frame_done,
    output reg fft_restart,
    //Modes and header status (to CPU MMIO 0x70)
    //mode indicates the following:
    //0x0A UART to CPU
    //0x8A UART to FFT
    //0xCA MIC to FFT
    output reg [1:0] mode,
    output reg [7:0] hdr_byte0,
    output reg [7:0] hdr_num_fft,

    //CPU and mic control flags
    input wire cpu_release,
    output wire mic_enable, //high only when in mic to fft mode
    output wire fft_src_mic //same as mic_enable.... could remove but too lazy
);

    //magic used for the header initially, otherwise we discard
    localparam [3:0] HDR_MAGIC = 4'hA;

    //states
    localparam [2:0] ST_WAIT_B0 = 3'd0,
                     ST_WAIT_B1 = 3'd1,
                     ST_CPU = 3'd2,
                     ST_FFT = 3'd3,
                     ST_MIC = 3'd4;

    reg [2:0] state;
    reg [7:0] frames_rem;
    reg ready_consumed;

    assign mic_enable = (state == ST_MIC);
    assign fft_src_mic = (state == ST_MIC);

    //Mode output (to CPU MMIO)
    //mode encoding: 0=wait, 1=cpu, 2=fft_uart, 3=fft_mic
    always @(*) begin
        case(state)
            ST_CPU:
                mode = 2'd1;
            ST_FFT:
                mode = 2'd2;
            ST_MIC:
                mode = 2'd3;
            default:
                mode = 2'd0;
        endcase
    end

    always @(posedge clk) begin
        if(rst) begin
            state <= ST_WAIT_B0;
            raw_rx_ack <= 1'b0;
            cpu_rx_data <= 8'b0;
            cpu_rx_ready <= 1'b0;
            fft_rx_data <= 8'b0;
            fft_rx_valid <= 1'b0;
            fft_restart <= 1'b0;
            hdr_byte0 <= 8'b0;
            hdr_num_fft <= 8'b0;
            frames_rem <= 8'b0;
            ready_consumed <= 1'b0;
        end else begin
            raw_rx_ack <= 1'b0;
            fft_rx_valid <= 1'b0;
            fft_restart <= 1'b0;

            //cpu ack will clear whether it is ready for rx or not
            if(cpu_rx_ack)
                cpu_rx_ready <= 1'b0;

            if(!raw_rx_ready)
                ready_consumed <= 1'b0;

            //Reader to header wait once CPU is done and not already n await stage
            if(cpu_release && (state == ST_CPU || state == ST_FFT || state == ST_MIC)) begin
                state <= ST_WAIT_B0;
            end

            //counter for fft frames because header sends how many frames we want to compute
            if(fft_frame_done && (state == ST_FFT || state == ST_MIC) && frames_rem != 8'd0) begin
                if(frames_rem == 8'd1)
                    state <= ST_WAIT_B0;
                else
                    frames_rem <= frames_rem - 8'd1;
            end

            //new byte
            if(raw_rx_ready && !ready_consumed) begin
                ready_consumed <= 1'b1;
                raw_rx_ack <= 1'b1;
                case(state)
                    //wait for first (zeroth) byte
                    ST_WAIT_B0: begin
                        if(raw_rx_data[3:0] == HDR_MAGIC) begin //ignore anything that's not the magic for first byte
                            hdr_byte0 <= raw_rx_data;
                            state <= ST_WAIT_B1;
                        end
                    end

                    //byte 1 that decodes header, aka for mode
                    ST_WAIT_B1: begin
                        hdr_num_fft <= raw_rx_data;

                        if(hdr_byte0[6]) begin
                            //mic source to fft
                            frames_rem <= raw_rx_data;
                            fft_restart <= 1'b1;
                            state <= ST_MIC;
                        end else if(hdr_byte0[7]) begin
                            //uart to fft
                            frames_rem <= raw_rx_data;
                            fft_restart <= 1'b1;
                            state <= ST_FFT;
                        end else begin
                            //uart to cpu
                            state <= ST_CPU;
                        end
                    end

                    //CPU mode
                    ST_CPU: begin
                        if(!cpu_rx_ready) begin
                            cpu_rx_data <= raw_rx_data;
                            cpu_rx_ready <= 1'b1;
                        end
                    end

                    //UART feeded to FFT directly mode
                    ST_FFT: begin
                        fft_rx_data <= raw_rx_data;
                        fft_rx_valid <= 1'b1;
                    end

                    //MIC to FFT mode
                    ST_MIC: begin
                        //discard all UART data since it doesnt matter for mic mode until we reset
                    end
                    default:
                        state <= ST_WAIT_B0;
                endcase
            end
        end
    end
endmodule