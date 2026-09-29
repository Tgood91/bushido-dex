import express from 'express';
const app=express(); app.use(express.json());
app.get('/api/health',(_req,res)=>res.json({status:'ok',network:'Base',chainId:8453,simulationOnly:true}));
app.get('/api/router/quotes',(req,res)=>{const amount=Number(req.query.amountIn)||0;res.json({success:true,simulationOnly:true,quotes:['1inch','lifi','0x'].map((router,i)=>({routerId:router,expectedOutput:String(Math.round(amount*(0.9995-i*.0002))),priceImpactPct:.15+i*.08,virtueComplianceScore:92-i*3}))})});
export default app;
