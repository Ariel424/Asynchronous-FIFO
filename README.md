# Asynchronous-FIFO
Implementation of an Asynchronous FIFO: Mastering Clock Domain Crossing and Metastability

Key Highlights:

● RTL Implementation: Designed a 16x8 dual-clock FIFO in Verilog, utilizing Gray code pointer conversion to ensure that only a single bit changes per clock cycle, significantly reducing the risk of glitches during synchronization.

● Metastability Mitigation: Integrated multi-stage (2-FF) synchronization chains to safely transfer read and write pointers across domains, ensuring stable and accurate Full/Empty flag generation despite frequency disparities.

● Modular Infrastructure: Leveraged a SystemVerilog Interface to encapsulate asynchronous signals, providing a clean, reusable foundation for advanced verification and FPGA-based system integration.

This project underscores my commitment to designing high-reliability hardware that addresses real-world synchronization challenges in modern digital systems.
