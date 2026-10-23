`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: UESTC
// Engineer: Haojie Wei
//
// Create Date: 2026/10/23
// Design Name:
// Module Name: nn_accelerator_top
// Project Name:
// Target Devices: PYNQ-Z2
// Tool Versions: Vivado 2023.1
// Description: 任务二 - 乘积累加(MAC)加速器，替换任务一的 instr_decoder + module_for_test。
//   端口与任务一版本完全一致，可直接覆盖替换，顶层连线不用改。
//
// 数据通路：
//   PS 经 pl_mac_test.py 每次发 64bit：{array2[3],array1[3],array2[2],array1[2],
//                                      array2[1],array1[1],array2[0],array1[0]}
//   每包拆 4 对有符号 8bit 做乘加 -> 18bit 部分和；连续收 CNT_MAX 包，累加到 30bit。
//   收齐后把 {1'b1, 33'b0, acc[29:0]} 推回 PS（最高位 1 = 结束标志；
//   PS 端把低 30bit 按有符号数解析）。
//////////////////////////////////////////////////////////////////////////////////

module nn_accelerator_top #(
    parameter DATA_WIDTH = 64
)(
    // base signals
    input         rst_n,
    input         onchip_clk,

    // input ports
    input [63:0]  din,
    input         din_valid,
    input         outfifo_almost_full,

    // output ports
    output [63:0] output_data,
    output        output_data_vld,
    output        acc_almost_full
);

    // 累加包数：必须与 pl_mac_test.py 实际发送的包数一致，对不上就改这里
    localparam CNT_MAX = 4096;

    // 30bit 有符号累加器：18bit 部分和 × 4096(2^12) 正好 30bit
    reg signed [29:0] acc;
    reg        [11:0] pkt_cnt;   // 计数 4096 个包需要 12bit
    reg               done;      // 4096 包收齐，等待把结果推出去

    // ---- 4 组有符号 8x8 乘法，积为 16bit 有符号 ----
    // 注意：不加 $signed() 的乘法按无符号算，权重一出现负数结果就全错
    wire signed [15:0] prod0 = $signed(din[15: 8]) * $signed(din[ 7: 0]); // a2[0]*a1[0]
    wire signed [15:0] prod1 = $signed(din[31:24]) * $signed(din[23:16]); // a2[1]*a1[1]
    wire signed [15:0] prod2 = $signed(din[47:40]) * $signed(din[39:32]); // a2[2]*a1[2]
    wire signed [15:0] prod3 = $signed(din[63:56]) * $signed(din[55:48]); // a2[3]*a1[3]

    // ---- 4 个积相加：18bit 有符号部分和 ----
    wire signed [17:0] psum = prod0 + prod1 + prod2 + prod3;

    // 上游反压：只有"结果等着发、暂不收新包"时才拉高，累加期间永远可收
    assign acc_almost_full = done;

    // 结果输出：等下游 TX FIFO 不满时推一拍，发完自动清零、自动开始下一轮
    assign output_data     = {1'b1, 33'b0, acc[29:0]};
    assign output_data_vld = done & ~outfifo_almost_full;

    always @(posedge onchip_clk or negedge rst_n) begin
        if (!rst_n) begin
            acc     <= 30'sd0;
            pkt_cnt <= 12'd0;
            done    <= 1'b0;
        end else if (done) begin
            // output_data_vld 已有效且下游可收 -> 清零，自动开始下一轮
            if (~outfifo_almost_full) begin
                acc     <= 30'sd0;
                pkt_cnt <= 12'd0;
                done    <= 1'b0;
            end
        end else if (din_valid) begin
            // 约定：din_valid 有效的当拍 din 即有效。
            // 若顶层是"读使能提前一拍、数据晚一拍"的结构，把 din 打一拍寄存后再参与乘加。
            acc <= acc + psum;
            if (pkt_cnt == CNT_MAX - 1)
                done <= 1'b1;   // 第 4096 个包：本拍累加完即收齐
            pkt_cnt <= pkt_cnt + 12'd1;
        end
    end

endmodule
