## 프로젝트 다운로드 및 실행

### 1. 준비 사항

- Vivado 2020.2 사용 권장
- 대상 FPGA: Cora Z7-07S (`xc7z007sclg400-1`)
- RTL 시뮬레이션에는 FPGA 보드가 필요하지 않습니다.
- 현재 배포 파일에는 생성된 Vivado 프로젝트가 포함되어 있어 새 프로젝트를 만들 필요가 없습니다.

### 2. 프로젝트 다운로드

아래 Release에서 `fpga-mlp-project_s7.zip`을 다운로드합니다.

[Release 페이지](https://github.com/2002minwoo-code/fpga-mlp-project/releases/tag/integration-s7)

[프로젝트 ZIP 직접 다운로드](https://github.com/2002minwoo-code/fpga-mlp-project/releases/download/integration-s7/fpga-mlp-project_s7.zip)

Release의 Assets 중 직접 첨부된 `fpga-mlp-project_s7.zip`을 선택해야 합니다.

`Source code (zip)`과 `Source code (tar.gz)`는 GitHub 저장소를 자동 압축한 파일이며, 별도로 첨부한 Vivado 프로젝트 ZIP을 포함하지 않습니다.

### 3. 압축 해제

ZIP을 원하는 위치에 압축 해제합니다.

예시:

```text
C:/FPGA/fpga-mlp-project/
├─ 04_dense_layer/
├─ 05_mlp_core/
├─ 06_uart/
├─ 07_top_integration/
├─ constraints/
├─ scripts/
└─ build/
   └─ vivado/
      └─ BMS_project.xpr
```

ZIP 파일 안에서 바로 프로젝트를 열지 말고, 먼저 전체 압축을 해제합니다.

소스와 메모리가 프로젝트 폴더 외부의 상대 경로로 연결되어 있으므로, `build` 폴더만 따로 옮기지 말고 위 폴더 구조를 유지합니다.

### 4. Vivado 프로젝트 열기

Vivado에서 `Open Project`를 선택하고 다음 파일을 엽니다.

```text
압축을 푼 위치/fpga-mlp-project/build/vivado/BMS_project.xpr
```

예시:

```text
C:/FPGA/fpga-mlp-project/build/vivado/BMS_project.xpr
```

### 5. 메모리 경로 설정

배포된 프로젝트의 `MEM_DIR`에는 작성자 컴퓨터의 경로가 저장되어 있습니다.

받은 컴퓨터의 경로로 변경하기 위해, 프로젝트를 연 상태에서 Vivado 하단의 `Tcl Console`에 다음 명령을 실행합니다.

```tcl
# 현재 .xpr 위치를 기준으로 프로젝트 최상위 폴더 계산
set repo_dir [file normalize [file join [get_property DIRECTORY [current_project]] ../..]]
set mem_dir [file join $repo_dir 07_top_integration tb mem]

# 메모리 폴더가 존재하는지 확인
if {![file isdirectory $mem_dir]} {
    error "Memory directory not found: $mem_dir"
}

# 합성용 Top의 메모리 경로
set_property generic "MEM_DIR=\"$mem_dir\"" [get_filesets sources_1]

# 시뮬레이션용 메모리 경로와 UART 속도
set_property generic "CPB=1085 MEM_DIR=\"$mem_dir\"" [get_filesets sim_1]

puts "Memory directory: $mem_dir"
```

이 명령은 RTL 소스를 수정하지 않고, Vivado 프로젝트의 Parameter 설정을 변경합니다.

`CPB`는 UART 1비트에 사용하는 클록 수입니다.

- `CPB=1085`: 125 MHz 클록에서 약 115200 baud에 해당하는 설정
- `CPB=16`: 테스트 시간을 줄이기 위한 고속 시뮬레이션 설정

고속 시뮬레이션을 하려면 위 명령의 `CPB=1085`를 `CPB=16`으로 바꿉니다.

### 6. Top 설정 확인

Sources 창에서 다음과 같이 설정되어 있는지 확인합니다.

| 구분 | Top Module |
|---|---|
| Design Sources | `board_top` |
| Simulation Sources | `tb_fpga_top` |

다르게 설정되어 있다면 해당 모듈을 우클릭하고 `Set as Top`을 선택합니다.

### 7. 통합 시뮬레이션 실행

1. 왼쪽 Flow Navigator에서 `Run Simulation`을 선택합니다.
2. `Run Behavioral Simulation`을 실행합니다.
3. 시뮬레이션 창이 열리면 Tcl Console에서 다음 명령을 실행합니다.

```tcl
run all
```

테스트가 끝날 때까지 기다립니다.

기존에 시뮬레이션 창이 열려 있었다면 닫고, Parameter 변경 후 다시 실행합니다.

### 8. 결과 확인

정상적으로 완료되면 다음과 같은 메시지가 출력됩니다.

```text
PASS: 33 real UART/MLP responses, 28 seven-feature golden vectors, all feature lanes, legacy packet rejection, checksum/framing rejection, reset recovery; CPB=1085
```

`CPB=16`으로 실행했다면 마지막 부분이 `CPB=16`으로 표시됩니다.

PASS 메시지는 다음 항목을 검증했다는 의미입니다.

- 실제 UART 및 MLP RTL을 연결한 통합 동작
- 7개 Feature를 사용하는 28개 기준 입력과 예상 출력 비교
- 각 Feature 위치의 데이터 전달
- 기존 형식 패킷 거부
- 체크섬 및 UART 프레이밍 오류 처리
- 리셋 이후 정상 동작 복구

정상 완료 시 테스트벤치의 `$finish`에 의해 시뮬레이션이 종료됩니다.

### 9. 시뮬레이션 이후

합성과 Implementation을 다시 실행하려면 시뮬레이션을 닫은 후 다음 순서로 진행합니다.

1. Run Synthesis
2. Run Implementation
3. Timing 및 DRC 결과 확인
4. Generate Bitstream

현재 배포 프로젝트에는 Cora Z7-07S용 핀 및 클록 제약이 포함되어 있습니다.

다른 보드에 사용할 경우 대상 FPGA, 클록, 핀 제약을 해당 보드에 맞게 변경해야 합니다.

## 검증 범위와 남은 작업

- 현재 Weight/Bias는 테스트용 데이터입니다.
- 시뮬레이션 PASS는 현재 테스트 데이터에 대한 RTL 동작 검증 결과입니다.
- 실제 학습 모델의 SOH 예측 정확도를 검증한 결과는 아닙니다.
- 실제 FPGA 보드 및 STM32와 연결한 UART 통신 검증은 별도로 진행해야 합니다.
