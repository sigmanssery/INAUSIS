import numpy as np
from ttcgs_golden_model import make_test_signal, dog_pipeline, NOISE_SAMPLES

t,x = make_test_signal()
x16 = x/(np.max(np.abs(x))+1e-9)*29000
res = dog_pipeline(x16)
feat = res['G_s3']
feat_i = np.clip(np.round(feat).astype(np.int64), -32768, 32767)

N_SQ=9; CAL_N=NOISE_SAMPLES; DEB=3
cal = feat_i[:CAL_N]
csum=int(cal.sum()); csumsq=int((cal**2).sum())
mean_sq=(csum*csum)//CAL_N
threshold=(N_SQ*(csumsq-mean_sq))//CAL_N
mu = csum//CAL_N      # NEW: mean for offset removal

print(f'mu={mu} threshold={threshold}')

# ABS mode WITH mu subtraction: cmp = x - mu
flag=np.zeros(len(feat_i),int); deb=0
for n in range(len(feat_i)):
    if n<CAL_N: continue
    cmp=int(feat_i[n])-mu
    if cmp*cmp>threshold:
        if deb>=DEB-1: flag[n]=1
        else: deb+=1; flag[n]=0
    else: deb=0; flag[n]=0

with open("abs_input.mem","w") as f:
    for v in feat_i: f.write(f"{int(v)&0xFFFF:04X}\n")
np.savez("expected_abs.npz", feat=feat_i, flag=flag, threshold=threshold, mu=mu)
fired=np.where(flag==1)[0]
print(f'ABS mode (G_s3, with mu): flags={flag.sum()}, first fired={fired[0] if len(fired)>0 else -1}')
