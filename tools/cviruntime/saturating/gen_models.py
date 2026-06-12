#!/usr/bin/env python3
# Генератор saturating-моделей для замера достижимого пика TPU cv181x.
# Каждая модель это одна тяжёлая операция с высокой арифметической
# интенсивностью (MAC на байт), чтобы держать MAC-массив занятым и подойти
# к паспортным ~0.7 TOPS. Делаем Conv 1x1, Conv 3x3 и GEMM в свипе размеров.
# Плюс на каждую модель пишем несколько случайных npz для калибровки INT8.
import os
import numpy as np
import onnx
from onnx import helper, TensorProto

OUT = os.path.dirname(os.path.abspath(__file__))
CALI_N = 4  # сколько случайных входов для run_calibration

def save_cali(name, shape):
    d = os.path.join(OUT, name + "_cali")
    os.makedirs(d, exist_ok=True)
    lst = []
    for i in range(CALI_N):
        x = (np.random.randn(*shape).astype(np.float32))
        p = os.path.join(d, f"s{i}.npz")
        np.savez(p, input=x)
        lst.append(p)
    with open(os.path.join(OUT, name + "_cali_list.txt"), "w") as f:
        f.write("\n".join(lst) + "\n")

def macs_str(m):
    return f"{m/1e6:.1f}M" if m < 1e9 else f"{m/1e9:.2f}G"

def conv(name, cin, cout, h, w, k):
    pad = k // 2
    macs = h * w * cin * cout * k * k
    x = helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, cin, h, w])
    y = helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, cout, h, w])
    wdata = (np.random.randn(cout, cin, k, k) * 0.05).astype(np.float32)
    W = helper.make_tensor("W", TensorProto.FLOAT, wdata.shape, wdata.flatten())
    node = helper.make_node("Conv", ["input", "W"], ["output"],
                            kernel_shape=[k, k], pads=[pad, pad, pad, pad],
                            strides=[1, 1])
    g = helper.make_graph([node], name, [x], [y], [W])
    m = helper.make_model(g, opset_imports=[helper.make_opsetid("", 13)])
    m.ir_version = 8
    onnx.checker.check_model(m)
    onnx.save(m, os.path.join(OUT, name + ".onnx"))
    save_cali(name, (1, cin, h, w))
    print(f"{name:24s} shape=[1,{cin},{h},{w}] k={k} MACs={macs_str(macs)} FLOPs~{macs_str(2*macs)}")

def gemm(name, M, K, N):
    macs = M * K * N
    x = helper.make_tensor_value_info("input", TensorProto.FLOAT, [M, K])
    y = helper.make_tensor_value_info("output", TensorProto.FLOAT, [M, N])
    bdata = (np.random.randn(K, N) * 0.05).astype(np.float32)
    B = helper.make_tensor("B", TensorProto.FLOAT, bdata.shape, bdata.flatten())
    node = helper.make_node("MatMul", ["input", "B"], ["output"])
    g = helper.make_graph([node], name, [x], [y], [B])
    m = helper.make_model(g, opset_imports=[helper.make_opsetid("", 13)])
    m.ir_version = 8
    onnx.checker.check_model(m)
    onnx.save(m, os.path.join(OUT, name + ".onnx"))
    save_cali(name, (M, K))
    print(f"{name:24s} shape=[{M},{K}]x[{K},{N}] MACs={macs_str(macs)} FLOPs~{macs_str(2*macs)}")

np.random.seed(1)
# свип: варьируем тип операции, число каналов, пространство и интенсивность
conv("conv1x1_c256_s64",  256, 256, 64, 64, 1)   # 268M MAC, средняя интенсивность
conv("conv1x1_c512_s64",  512, 512, 64, 64, 1)   # 1.07G MAC
conv("conv3x3_c256_s64",  256, 256, 64, 64, 3)   # 2.42G MAC, высокая интенсивность
conv("conv3x3_c384_s48",  384, 384, 48, 48, 3)   # 2.86G MAC
gemm("gemm_m256_k1024_n1024", 256, 1024, 1024)   # 268M MAC, matrix-mode
print("done")
