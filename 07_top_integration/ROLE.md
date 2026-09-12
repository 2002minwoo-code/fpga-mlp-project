# FPGA Top 및 전체 통합

담당: 임재민님

## 담당 내용

- 각 모듈의 포트와 Parameter 확인
- UART, Buffer, MLP Core 연결
- Clock과 Reset 연결
- 전체 Top Module 작성
- 전체 통합 Testbench 작성
- UART 입력부터 MLP 결과 출력까지 Simulation
- 통합 과정에서 발생하는 연결 오류 확인

전체 Testbench는 각 모듈의 Testbench에서 사용한 입력 생성 방법과 검증 방법을 참고하여 새로 작성합니다.

Cora Z7 핀 설정과 Bitstream 생성은 전체 RTL Simulation이 완료된 이후 진행합니다.

## 담당 파일

- rtl/fpga_top.sv
- rtl/reset_sync.sv
- tb/tb_fpga_top.sv
