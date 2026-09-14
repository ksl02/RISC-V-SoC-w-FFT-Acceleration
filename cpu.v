`timescale 1ns/1ps

module riscv_core_pipelined #(
    parameter integer IMEM_WORDS = 8192, //number of instructions
    parameter integer DMEM_WORDS = 2048, //number of data memory words
    parameter [31:0] RESET_PC = 32'h0000_3000 //entrypoint for the bootloader
) (
    input wire clk,
    input wire rst,
    output reg [15:0] led_out,
    output wire [31:0] dbg_pc, //pc output just for debugging
    output wire [31:0] dbg_x10, //x10 output just for debugging 

    //uart inputs from uart router
    input wire uart_rx_ready,
    input wire [7:0] uart_rx_data,
    input wire uart_tx_busy, //whether or not we can transmit
    //uart output to uart router
    output reg uart_rx_ack, //ack that we recv rx
    output reg uart_tx_wr, //output transmit data to uart
    output reg [7:0] uart_tx_data, //output transmit data to uart router

    //TODO: remove, no longer using
    output reg [15:0] seg_override_val,
    output reg seg_override_mode,

    //uart router status (i.e. header and changing mode)
    //where mode determines path routing (uart -> CPU, uart -> FFT, pmodMIC -> FFT)
    input wire [1:0] router_mode,
    input wire [7:0] router_hdr_byte0,
    input wire [7:0] router_hdr_num_fft,
    output reg router_cpu_release, //pulse

    //FFT to BRAM
    output reg [5:0] fft_bram_rd_addr, //bin index
    input wire [47:0] fft_bram_rd_data, //format: {imag[23:0], real[23:0]} (right now sign extended 8 bits)
    input wire fft_frame_ready,
    output reg fft_frame_ack //pulse, let FFT manager know we've read bin
);
    //instruction memory, initially loaded to bootloader
    reg [31:0] imem [0:IMEM_WORDS-1];
    initial begin
        $readmemh("boot.hex", imem);
    end
    reg [31:0] dmem [0:DMEM_WORDS-1];

    //register file
    //32 registers, each 32bit
    reg [31:0] rf [0:31];

    wire [4:0] id_rs1; //in rs1 id
    wire [4:0] id_rs2; //in rs2 id

    reg wb_valid; //writeback stage data valid
    reg [4:0] wb_rd; //rd id
    reg wb_regwrite; //should write to reg signal
    reg wb_memtoreg; //memory to reg signal, write wb_wdata to wb_rd
    reg [31:0] wb_alu_out;
    reg [31:0] wb_mem_rdata;
    reg wb_is_link;
    reg [31:0] wb_link_value; //return address for instrs like jalr
    wire [31:0] wb_wdata; //writeback data, can be wb_mem_rdata or wb_alu_out or wb_link_value

    reg ex_do_take; //whether or not to take some branch or PC + 4
    reg [31:0] ex_pc_target; //target PC for next instruction

    reg idex_valid; //EX stage has valid instruction instead of bubble
    reg [31:0] idex_pc; //stored pc value used for branching

    //register file values for ex stage
    reg [31:0] idex_rs1_val, idex_rs2_val;
    reg [4:0] idex_rs1, idex_rs2, idex_rd;

    //funct3,7 for ALU ex
    reg [2:0] idex_funct3;
    reg [6:0] idex_funct7;

    reg [6:0] idex_opcode;
    reg [31:0] idex_imm;

    //control signals for id to ex stage boundary
    reg idex_regwrite, idex_memread, idex_memwrite, idex_memtoreg;
    reg idex_branch, idex_jal, idex_jalr;
    reg idex_alu_src_imm;
    reg [2:0] idex_alu_op;
    reg idex_auipc, idex_lui;

    //data values for ex to mem stage boundary
    reg [31:0] exmem_alu_out; //output from ALU at end of ex stage to mem
    reg [31:0] exmem_rs2_fwd; //forwarded rs2 for mem stage from ex stage
    reg [4:0] exmem_rd;
    reg [31:0] exmem_link_value;

    //control signals for ex to mem stage boundary
    reg exmem_valid, exmem_regwrite, exmem_memread, exmem_memwrite, exmem_memtoreg, exmem_is_link;

    //reset all register values on reset
    integer i;
    always @(posedge clk) begin
        if(rst) begin
            for(i=0;i<32;i=i+1) begin
                rf[i] <= 32'b0;
            end
        end else begin
            if(wb_regwrite && (wb_rd != 5'd0))
                rf[wb_rd] <= wb_wdata;
        end
    end

    //combinatorial result for rs1 and rs2 controlled by whether or not we are writing and if the write register is the current register
    //rsx = wb_wdata if we are writing, otherwise rsx = rsx
    //x0 always 0
    wire [31:0] rf_rs1 = (id_rs1 == 5'd0) ? 32'b0 : (wb_regwrite && wb_rd == id_rs1) ? wb_wdata : rf[id_rs1];
    wire [31:0] rf_rs2 = (id_rs2 == 5'd0) ? 32'b0 : (wb_regwrite && wb_rd == id_rs2) ? wb_wdata : rf[id_rs2];

    assign dbg_x10 = rf[10];

    //instruction fetch
    reg [31:0] pc;
    assign dbg_pc = pc;
    wire [$clog2(IMEM_WORDS)-1:0] imem_rd_addr = pc[$clog2(IMEM_WORDS)+1:2];
    wire [31:0] if_instr = imem[imem_rd_addr];

    //ex stage branching and PC logic.. branching determined in EX stage and used by next fetch stage
    //PC either next instruction or branch
    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] pc_next = ex_do_take ? ex_pc_target : pc_plus4;

    //IF to ID boundary pipeline regs
    reg [31:0] ifid_pc;
    reg [31:0] ifid_instr;
    reg ifid_valid;

    //Instruction decode stage
    //instruction encoding format reference: https://www.cs.sfu.ca/~ashriram/Courses/CS295/assets/notebooks/RISCV/RISCV_CARD.pdf
    wire [6:0] id_opcode = ifid_instr[6:0];
    wire [4:0] id_rd = ifid_instr[11:7];
    wire [2:0] id_funct3 = ifid_instr[14:12];
    assign id_rs1 = ifid_instr[19:15];
    assign id_rs2 = ifid_instr[24:20];
    wire [6:0] id_funct7 = ifid_instr[31:25];

    wire [31:0] imm_i = {{20{ifid_instr[31]}}, ifid_instr[31:20]};
    wire [31:0] imm_s = {{20{ifid_instr[31]}}, ifid_instr[31:25], ifid_instr[11:7]};
    wire [31:0] imm_b = {{19{ifid_instr[31]}}, ifid_instr[31], ifid_instr[7], ifid_instr[30:25], ifid_instr[11:8], 1'b0};
    wire [31:0] imm_u = {ifid_instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{ifid_instr[31]}}, ifid_instr[31], ifid_instr[19:12], ifid_instr[20], ifid_instr[30:21], 1'b0};

    //values of alu_op, controlled mostly by func3
    localparam [2:0] ALU_ADD = 3'd0,
                     ALU_SUB = 3'd1,
                     ALU_AND = 3'd2,
                     ALU_OR = 3'd3,
                     ALU_XOR = 3'd4,
                     ALU_SLT = 3'd5,
                     ALU_SLTU= 3'd6,
                     ALU_SHF = 3'd7;

    //control signals for id stage
    reg id_regwrite, id_memread, id_memwrite, id_memtoreg, id_branch, id_jal, id_jalr, id_alu_src_imm, id_auipc, id_lui;

    reg [2:0] id_alu_op;
    reg [31:0] id_imm;

    always @(*) begin
        id_regwrite = 1'b0;
        id_memread = 1'b0;
        id_memwrite = 1'b0;
        id_memtoreg = 1'b0;
        id_branch = 1'b0;
        id_jal = 1'b0;
        id_jalr = 1'b0;
        id_alu_src_imm= 1'b0;
        id_alu_op = ALU_ADD; //default ALU operation
        id_imm = 32'b0;
        id_auipc = 1'b0;
        id_lui = 1'b0;

        //ID control signal manager
        case(id_opcode)
            7'b0110111: begin
                id_regwrite=1'b1;
                id_lui=1'b1;
                id_imm=imm_u;
            end
            7'b0010111: begin
                id_regwrite=1'b1; 
                id_auipc=1'b1;
                id_imm=imm_u;
            end
            7'b1101111: begin 
                id_regwrite=1'b1; 
                id_jal=1'b1;
                id_imm=imm_j;
            end
            7'b1100111: begin
                id_regwrite=1'b1;
                id_jalr=1'b1;
                id_alu_src_imm=1'b1;
                id_imm=imm_i; 
                id_alu_op=ALU_ADD;
            end
            7'b1100011: begin 
                id_branch=1'b1;
                id_imm=imm_b;
                id_alu_op=ALU_SUB;
            end
            7'b0000011: begin
                id_regwrite=1'b1;
                id_memread=1'b1;
                id_memtoreg=1'b1;
                id_alu_src_imm=1'b1;
                id_imm=imm_i;
                id_alu_op=ALU_ADD;
            end
            7'b0100011: begin
                id_memwrite=1'b1;
                id_alu_src_imm=1'b1;
                id_imm=imm_s;
                id_alu_op=ALU_ADD;
            end
            7'b0010011: begin
                id_regwrite=1'b1;
                id_alu_src_imm=1'b1;
                id_imm=imm_i;
                case(id_funct3)
                    3'b000: id_alu_op = ALU_ADD;
                    3'b010: id_alu_op = ALU_SLT;
                    3'b011: id_alu_op = ALU_SLTU;
                    3'b100: id_alu_op = ALU_XOR;
                    3'b110: id_alu_op = ALU_OR;
                    3'b111: id_alu_op = ALU_AND;
                    3'b001: id_alu_op = ALU_SHF;
                    3'b101: id_alu_op = ALU_SHF;
                    default: id_alu_op = ALU_ADD;
                endcase
            end
            7'b0110011: begin
                id_regwrite=1'b1; id_alu_src_imm=1'b0;
                case(id_funct3)
                    3'b000: id_alu_op = (id_funct7[5] ? ALU_SUB : ALU_ADD);
                    3'b111: id_alu_op = ALU_AND;
                    3'b110: id_alu_op = ALU_OR;
                    3'b100: id_alu_op = ALU_XOR;
                    3'b010: id_alu_op = ALU_SLT;
                    3'b011: id_alu_op = ALU_SLTU;
                    3'b001: id_alu_op = ALU_SHF;
                    3'b101: id_alu_op = ALU_SHF;
                    default: id_alu_op = ALU_ADD;
                endcase
            end
        endcase
    end

    //based on opcode determine if function uses rs2 for hazard detection
    function automatic uses_rs2(input [6:0] opc);
        begin
            case(opc)
                7'b0100011: uses_rs2=1'b1;
                7'b1100011: uses_rs2=1'b1;
                7'b0110011: uses_rs2=1'b1;
                default: uses_rs2=1'b0;
            endcase
        end
    endfunction

    //hazard detection id -> ex stages
    (* max_fanout = 32 *) reg stall;
    always @(*) begin
        stall = 1'b0;
        if(idex_valid && idex_memread && (idex_rd != 5'd0)) begin
            if((id_rs1==idex_rd) || ((id_rs2==idex_rd) && uses_rs2(id_opcode))) begin
                stall = 1'b1;
            end
        end
    end

    //forwarding logic
    reg [1:0] forwardA_sel, forwardB_sel;

    //forward register value or writeback data depending on forwardA_sel result
    (* max_fanout = 32 *) wire [31:0] ex_rs1_fwd = forwardA_sel == 2'd0 ? idex_rs1_val : forwardA_sel == 2'd1 ? exmem_alu_out : wb_wdata;
    (* max_fanout = 32 *) wire [31:0] ex_rs2_fwd = forwardB_sel == 2'd0 ? idex_rs2_val : forwardB_sel == 2'd1 ? exmem_alu_out : wb_wdata;

    //whether we should forward logic
    always @(*) begin
        forwardA_sel = 2'd0;
        forwardB_sel = 2'd0;
        
        //If the instruction is going to write a register and is not x0, we set forward selects to 1
        //which indicates we should use exmem_alu_out 
        if(exmem_regwrite && (exmem_rd != 5'd0)) begin
            if(exmem_rd == idex_rs1) begin
                forwardA_sel = 2'd1;
            end
            if(exmem_rd == idex_rs2) begin
                forwardB_sel = 2'd1;
            end
        end

        //Forward from WB if the current EX-stage instruction needs rs1/rs2, and WB is writing that same register (not x0), and EX/MEM not writing to it
        if(wb_regwrite && (wb_rd != 5'd0) && !(exmem_regwrite && (exmem_rd != 0) && (exmem_rd == idex_rs1)) && (wb_rd == idex_rs1)) begin
            forwardA_sel = 2'd2;
        end
        if(wb_regwrite && (wb_rd != 5'd0) && !(exmem_regwrite && (exmem_rd != 0) && (exmem_rd == idex_rs2)) && (wb_rd == idex_rs2)) begin
            forwardB_sel = 2'd2;
        end
    end

    //execute stage and ALU logic
    wire [31:0] ex_opA = idex_lui ? 32'b0 : ex_rs1_fwd;
    wire [31:0] ex_opB = idex_alu_src_imm ? idex_imm : ex_rs2_fwd;
    reg [31:0] ex_alu_out;

    always @(*) begin
        case(idex_alu_op)
            ALU_ADD: begin
                ex_alu_out = ex_opA + ex_opB;
                if(idex_lui)
                    ex_alu_out = idex_imm;
                if(idex_auipc)
                    ex_alu_out = idex_pc + idex_imm;
            end
            ALU_SUB: ex_alu_out = ex_opA - ex_opB;
            ALU_AND: ex_alu_out = ex_opA & ex_opB;
            ALU_OR: ex_alu_out = ex_opA | ex_opB;
            ALU_XOR: ex_alu_out = ex_opA ^ ex_opB;
            ALU_SLT: ex_alu_out = ($signed(ex_opA)<$signed(ex_opB)) ? 32'd1 : 32'd0;
            ALU_SLTU: ex_alu_out = (ex_opA<ex_opB) ? 32'd1 : 32'd0;
            ALU_SHF: begin
                case(idex_funct3)
                    3'b001: ex_alu_out = ex_opA << ex_opB[4:0];
                    3'b101: if(idex_funct7[5])
                                ex_alu_out = $signed(ex_opA) >>> ex_opB[4:0];
                            else
                                ex_alu_out = ex_opA >> ex_opB[4:0];
                    default: ex_alu_out = ex_opA + ex_opB;
                endcase
            end
            default: ex_alu_out = ex_opA + ex_opB;
        endcase
    end

    always @(*) begin
        ex_do_take = 1'b0;
        ex_pc_target = 32'b0;
        if(idex_valid) begin
            if(idex_jal) begin
                ex_do_take = 1'b1;
                ex_pc_target = idex_pc + idex_imm;
            end else if(idex_jalr) begin
                ex_do_take = 1'b1;
                ex_pc_target = (ex_rs1_fwd + idex_imm) & 32'hFFFF_FFFE;
            end else if(idex_branch) begin
                case(idex_funct3)
                    3'b000: ex_do_take = (ex_rs1_fwd == ex_rs2_fwd);
                    3'b001: ex_do_take = (ex_rs1_fwd != ex_rs2_fwd);
                    3'b100: ex_do_take = ($signed(ex_rs1_fwd) < $signed(ex_rs2_fwd));
                    3'b101: ex_do_take = ($signed(ex_rs1_fwd) >= $signed(ex_rs2_fwd));
                    3'b110: ex_do_take = (ex_rs1_fwd < ex_rs2_fwd);
                    3'b111: ex_do_take = (ex_rs1_fwd >= ex_rs2_fwd);
                    default: ex_do_take = 1'b0;
                endcase
                ex_pc_target = idex_pc + idex_imm;
            end
        end
    end

    wire [31:0] ex_link = idex_pc + 32'd4;

    //mem stage

    reg [31:0] mem_rdata;

    wire [31:0] mem_addr = exmem_alu_out;
    wire [31:0] mem_wdata = exmem_rs2_fwd;

    //mmio for leds
    wire is_led_mmio = (mem_addr == 32'h0000_0010);

    //mmio for uart
    wire is_uart_rx_mmio = (mem_addr == 32'h0000_0020);
    wire is_uart_tx_mmio = (mem_addr == 32'h0000_0030);
    wire is_uart_st_mmio = (mem_addr == 32'h0000_0040);

    //mmio for seven segment display
    wire is_seg_val_mmio = (mem_addr == 32'h0000_0050);
    wire is_seg_mod_mmio = (mem_addr == 32'h0000_0060);


    //mmio for fft
    wire is_router_mmio = (mem_addr == 32'h0000_0070); //R/W
    wire is_fft_addr_mmio = (mem_addr == 32'h0000_0080); //W: set bin addr
    wire is_fft_real_mmio = (mem_addr == 32'h0000_0084); //R: real[23:0]
    wire is_fft_imag_mmio = (mem_addr == 32'h0000_0088); //R: imag[23:0]

    //bootloader mmio
    wire is_imem_addr_mmio = (mem_addr == 32'h0000_00A0); //W: imem write addr
    wire is_imem_data_mmio = (mem_addr == 32'h0000_00A4); //W: imem write data
    wire is_pc_set_mmio = (mem_addr == 32'h0000_00A8); //W: force PC jump

    reg [31:0] imem_wr_addr; //index into imem
    reg pc_force; //whether to force pc to an address from bootloader
    reg [31:0] pc_force_addr; //target address for forced jump to new pc

    //The MMIO decode sets imem_wr_pending; on the NEXT cycle the registered imem_wr_en drives the BRAM write-enable directly
    reg imem_wr_pending; //set by MMIO decode
    reg [31:0] imem_wr_data_reg; //write data
    reg [$clog2(IMEM_WORDS)-1:0] imem_wr_addr_reg; //write address

    wire is_any_mmio = is_led_mmio | is_uart_rx_mmio | is_uart_tx_mmio | is_uart_st_mmio | is_seg_val_mmio | is_seg_mod_mmio | is_router_mmio | is_fft_addr_mmio | is_fft_real_mmio | is_fft_imag_mmio | is_imem_addr_mmio | is_imem_data_mmio | is_pc_set_mmio;

    always @(*) begin
        mem_rdata = 32'b0;
        uart_rx_ack = 1'b0;

        if(exmem_memread) begin
            if(is_uart_rx_mmio) begin
                mem_rdata = {24'b0, uart_rx_data};
                uart_rx_ack = 1'b1;
            end else if(is_uart_st_mmio) begin
                mem_rdata = {30'b0, uart_tx_busy, uart_rx_ready};
            end else if(is_router_mmio) begin
            //[31:24] = hdr_num_fft
            //[23:16] = hdr_byte0 (streaming, options, enable_fft, etc.)
            //[15:4] = reserved (12 bits)
            //[3] = fft_frame_ready
            //[2] = reserved
            //[1:0] = router_mode
            mem_rdata = {router_hdr_num_fft, router_hdr_byte0, 12'b0, fft_frame_ready, 1'b0, router_mode};
            end else if(is_fft_real_mmio) begin
                //sign-extend 24-bit real to 32-bit
                mem_rdata = {{8{fft_bram_rd_data[23]}}, fft_bram_rd_data[23:0]};
            end else if(is_fft_imag_mmio) begin
                //sign-extend 24-bit imag to 32-bit
                mem_rdata = {{8{fft_bram_rd_data[47]}}, fft_bram_rd_data[47:24]};
            end else if(!is_any_mmio) begin
                mem_rdata = dmem[mem_addr[$clog2(DMEM_WORDS)+1:2]];
            end
        end
    end

    //regwrite
    always @(posedge clk) begin
        uart_tx_wr <= 1'b0;
        uart_tx_data <= 8'b0;
        router_cpu_release <= 1'b0;
        fft_frame_ack <= 1'b0;

        if(rst) begin
            led_out <= 16'b0;
            seg_override_val <= 16'b0;
            seg_override_mode <= 1'b0;
            fft_bram_rd_addr <= 6'b0;
            imem_wr_addr <= 32'b0;
            pc_force <= 1'b0;
            pc_force_addr <= 32'b0;
            imem_wr_pending <= 1'b0;
            imem_wr_data_reg <= 32'b0;
            imem_wr_addr_reg <= {$clog2(IMEM_WORDS){1'b0}};
        end else begin
            pc_force <= 1'b0; //clear pc force conntinuously so it doesnt constantly force back to whatever the force addr is

            //wriet to imem
            if(imem_wr_pending) begin
                imem[imem_wr_addr_reg] <= imem_wr_data_reg;
                imem_wr_pending <= 1'b0;
            end

            if(exmem_memwrite) begin
                if(is_led_mmio) begin
                    led_out <= mem_wdata[15:0];
                end else if(is_uart_tx_mmio) begin
                    uart_tx_data <= mem_wdata[7:0];
                    uart_tx_wr <= 1'b1;
                end else if(is_seg_val_mmio) begin
                    seg_override_val <= mem_wdata[15:0];
                end else if(is_seg_mod_mmio) begin
                    seg_override_mode <= mem_wdata[0];
                end else if(is_router_mmio) begin
                    //[0] = cpu_release pulse
                    //[1] = fft_frame_ack pulse
                    router_cpu_release <= mem_wdata[0];
                    fft_frame_ack <= mem_wdata[1];
                end else if(is_fft_addr_mmio) begin
                    fft_bram_rd_addr <= mem_wdata[5:0];
                end else if(is_imem_addr_mmio) begin
                    //bootloader: set word-index for next write to imem
                    imem_wr_addr <= mem_wdata;
                end else if(is_imem_data_mmio) begin
                    imem_wr_pending <= 1'b1;
                    imem_wr_data_reg <= mem_wdata;
                    imem_wr_addr_reg <= imem_wr_addr[$clog2(IMEM_WORDS)-1:0];
                end else if(is_pc_set_mmio) begin
                    //force jump to PC
                    pc_force <= 1'b1;
                    pc_force_addr <= mem_wdata;
                end else if(!is_any_mmio) begin
                    dmem[mem_addr[$clog2(DMEM_WORDS)+1:2]] <= mem_wdata;
                end
            end
        end
    end

    //wb stage
    assign wb_wdata = wb_is_link ? wb_link_value : wb_memtoreg ? wb_mem_rdata : wb_alu_out;

    //flush on branch
    (* max_fanout = 32 *) wire flush_ifid = ex_do_take | pc_force;
    (* max_fanout = 32 *) wire flush_idex = ex_do_take | pc_force;

    always @(posedge clk) begin
        if(rst) begin
            pc <= RESET_PC;
            ifid_pc <= 32'b0;
            ifid_instr <= 32'h0000_0013;
            ifid_valid <= 1'b0;
            idex_valid <= 1'b0;
            exmem_valid <= 1'b0;
            wb_valid <= 1'b0;
        end else begin
            if(pc_force)
                pc <= pc_force_addr;
            else if(!stall)
                pc <= pc_next;

            if(flush_ifid) begin
                ifid_instr <= 32'h0000_0013;
                ifid_valid <= 1'b0;
            end else if(!stall) begin
                ifid_pc <= pc;
                ifid_instr <= if_instr;
                ifid_valid <= 1'b1;
            end

            // On flush: data registers are don't-care
            // On stall: data should hold
            // Control signals (idex_valid, regwrite, etc.) are cleared on flush OR stall
            if(!stall) begin
                idex_pc <= ifid_pc;
                idex_rs1_val <= rf_rs1;
                idex_rs2_val <= rf_rs2;
                idex_rs1 <= id_rs1;
                idex_rs2 <= id_rs2;
                idex_rd <= id_rd;
                idex_funct3 <= id_funct3;
                idex_funct7 <= id_funct7;
                idex_opcode <= id_opcode;
                idex_imm <= id_imm;
                idex_alu_src_imm <= id_alu_src_imm;
                idex_alu_op <= id_alu_op;
                idex_auipc <= id_auipc;
                idex_lui <= id_lui;
            end

            if(flush_idex || stall) begin
                idex_valid <= 1'b0;
                idex_regwrite <= 1'b0;
                idex_memwrite <= 1'b0;
                idex_memread <= 1'b0;
                idex_memtoreg <= 1'b0;
                idex_branch <= 1'b0;
                idex_jal <= 1'b0;
                idex_jalr <= 1'b0;
            end else begin
                idex_valid <= ifid_valid;
                idex_regwrite <= id_regwrite;
                idex_memread <= id_memread;
                idex_memwrite <= id_memwrite;
                idex_memtoreg <= id_memtoreg;
                idex_branch <= id_branch;
                idex_jal <= id_jal;
                idex_jalr <= id_jalr;
            end

            //ex/mem pipeline regs
            exmem_valid <= idex_valid;
            exmem_alu_out <= ex_alu_out;
            exmem_rs2_fwd <= ex_rs2_fwd;
            exmem_rd <= idex_rd;
            exmem_regwrite <= idex_regwrite;
            exmem_memread <= idex_memread;
            exmem_memwrite <= idex_memwrite;
            exmem_memtoreg <= idex_memtoreg;
            exmem_is_link <= (idex_jal || idex_jalr);
            exmem_link_value <= ex_link;

            //mem/wb pipeline regs
            wb_valid <= exmem_valid;
            wb_rd <= exmem_rd;
            wb_regwrite <= exmem_regwrite;
            wb_memtoreg <= exmem_memtoreg;
            wb_alu_out <= exmem_alu_out;
            wb_mem_rdata <= mem_rdata;
            wb_is_link <= exmem_is_link;
            wb_link_value <= exmem_link_value;
        end
    end

endmodule