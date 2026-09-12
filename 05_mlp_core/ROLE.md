# MLP Core 및 Controller

담당: 전윤하님

## 담당 내용

- Dense Layer와 ReLU 연결
- Layer 실행 순서 제어
- Layer 사이의 결과 전달
- mlp_start, mlp_busy, mlp_done 신호 처리
- 최종 MLP 결과 출력
- 전체 MLP Testbench 작성

## 기본 구조

Feature → Dense Layer 1 → ReLU → Dense Layer 2 → ReLU → Output Layer → SOH

Hidden Layer 뒤에는 ReLU를 적용하고, Output Layer에는 우선 적용하지 않습니다.

## 담당 파일

- rtl/mlp_controller.sv
- rtl/mlp_core.sv
- tb/tb_mlp_core.sv
