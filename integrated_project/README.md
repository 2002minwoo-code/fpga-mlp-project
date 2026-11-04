# FPGA MLP 통합 프로젝트

기존 모듈별 폴더와 별도로 보관하는 Vivado 통합 프로젝트입니다.

## 구성

- MLP 구조: 7 → 16 → 8 → 1
- UART 입력부터 MLP 결과 송신까지 통합
- 통합 RTL 및 Testbench 포함
- Weight/Bias와 검증용 메모리 데이터 포함

## 현재 검증 상태

- 통합 UART/MLP 시뮬레이션 PASS
- Bitstream 생성 완료
- 실제 FPGA 보드에서 동작 검증은 진행 전
- 현재 Weight/Bias는 실제 학습 모델이 아닌 테스트용 데이터

## 실행 방법

1. ZIP 파일을 다운로드하고 압축을 풉니다.
2. build/vivado/BMS_project.xpr를 Vivado에서 엽니다.
3. MEM_DIR을 압축을 푼 컴퓨터의 메모리 폴더 경로로 변경합니다.
4. 통합 시뮬레이션을 실행합니다.

Vivado 버전은 프로젝트를 생성한 버전과 동일한 버전 사용을 권장합니다.
