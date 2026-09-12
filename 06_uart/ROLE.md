# UART RX/TX 및 데이터 변환

담당: 이민우

## 담당 내용

- UART 통신속도 생성
- UART RX 데이터 수신
- UART TX 데이터 송신
- 여러 Byte 연속 송수신
- 수신 Byte를 Feature 값으로 변환
- MLP 결과를 Byte 단위로 송신
- Loopback Test
- UART Testbench 작성

## 담당 파일

- rtl/uart_baud_gen.sv
- rtl/uart_rx.sv
- rtl/uart_tx.sv
- rtl/uart_packet_rx.sv
- rtl/uart_packet_tx.sv
- tb/tb_uart_rx.sv
- tb/tb_uart_tx.sv
- tb/tb_uart_loopback.sv
