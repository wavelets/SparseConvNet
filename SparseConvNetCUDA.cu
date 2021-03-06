#include "SparseConvNetCUDA.h"
#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <chrono>
#include <cassert>
#include <algorithm>
#include "cudaUtilities.h"
#include "utilities.h"
#include "SigmoidLayer.h"
#include "NetworkInNetworkLayer.h"
#include "ConvolutionalLayer.h"
#include "ReallyConvolutionalLayer.h"
#include "ConvolutionalTriangularLayer.h"
#include "MaxPoolingLayer.h"
#include "MaxPoolingTriangularLayer.h"
#include "TerminalPoolingLayer.h"
#include "IndexLearnerLayer.h"
#include "SoftmaxClassifier.h"
#include "BatchProducer.h"
#include "SpatiallySparseDataset.h"


SparseConvNetCUDA::SparseConvNetCUDA(int dimension,
                                     int nInputFeatures,
                                     int nClasses,
                                     int pciBusID,
                                     int nTop) :
  dimension(dimension),
  nInputFeatures(nInputFeatures),
  nClasses(nClasses),
  nTop(nTop) {
  std::cout << "Sparse CNN - dimension=" << dimension << " nInputFeatures=" << nInputFeatures << " nClasses=" << nClasses << std::endl;
  nOutputFeatures=nInputFeatures;
  deviceID=initializeGPU(pciBusID);
  }


void SparseConvNetCUDA::addLearntLayer(int nFeatures,
                                       ActivationFunction activationFn,
                                       float dropout,
                                       float alpha) {
  if (activationFn!=SOFTMAX)
    nFeatures=max(KERNELBLOCKSIZE,intRound(nFeatures,KERNELBLOCKSIZE));
  if (dropout>0)
    dropout=1-intRound(nFeatures*(1-dropout),KERNELBLOCKSIZE)*1.0f/nFeatures;
  layers.push_back(new NetworkInNetworkLayer(nOutputFeatures, nFeatures, dropout, activationFn, alpha));
  nOutputFeatures=nFeatures;
}
void SparseConvNetCUDA::addNetworkInNetworkLayer(int nFeatures,
                                                 ActivationFunction activationFn,
                                                 float dropout) {
  addLearntLayer(nFeatures, activationFn, dropout, 1.0f);
}
void SparseConvNetCUDA::addConvolutionalLayer(int nFeatures,
                                              int filterSize,
                                              int filterStride,
                                              ActivationFunction activationFn,
                                              float dropout,
                                              int minActiveInputs,
                                              float poolingToFollow) {
  if (layers.size()==0+100000) { //Use for 0-th layer??
    layers.push_back(new ReallyConvolutionalLayer(nOutputFeatures, nFeatures, filterSize, filterStride, dimension, activationFn, dropout, minActiveInputs, poolingToFollow));
    nOutputFeatures=nFeatures;
  } else {
    if (filterSize>1) {
      layers.push_back(new ConvolutionalLayer(filterSize, filterStride, dimension, nOutputFeatures, minActiveInputs));
      nOutputFeatures*=ipow(filterSize,dimension);
    }
    addLearntLayer(nFeatures,activationFn,dropout,powf(filterSize*1.0/filterStride/poolingToFollow,2));
  }
}
void SparseConvNetCUDA::addLeNetLayerMP(int nFeatures, int filterSize, int filterStride, int poolSize, int poolStride, ActivationFunction activationFn, float dropout, int minActiveInputs) {
  addConvolutionalLayer(nFeatures,filterSize,filterStride,activationFn,dropout,minActiveInputs,poolSize);
  if (poolSize>1) {
    layers.push_back(new MaxPoolingLayer(poolSize, poolStride,dimension));
  }
}
void SparseConvNetCUDA::addLeNetLayerROFMP(int nFeatures, int filterSize, int filterStride, int poolSize, float fmpShrink, ActivationFunction activationFn, float dropout, int minActiveInputs) {
  addConvolutionalLayer(nFeatures,filterSize,filterStride,activationFn,dropout,minActiveInputs,fmpShrink);
  if (fmpShrink>1) {
    layers.push_back(new RandomOverlappingFractionalMaxPoolingLayer(poolSize,fmpShrink,dimension));
  }
}
void SparseConvNetCUDA::addLeNetLayerPOFMP(int nFeatures, int filterSize, int filterStride, int poolSize, float fmpShrink, ActivationFunction activationFn, float dropout, int minActiveInputs) {
  addConvolutionalLayer(nFeatures,filterSize,filterStride,activationFn,dropout,minActiveInputs,fmpShrink);
  if (fmpShrink>1)
    layers.push_back(new PseudorandomOverlappingFractionalMaxPoolingLayer(poolSize,fmpShrink,dimension));
}

void SparseConvNetCUDA::addTriangularConvolutionalLayer(int nFeatures,
                                                        int filterSize,
                                                        int filterStride,
                                                        ActivationFunction activationFn,
                                                        float dropout,
                                                        int minActiveInputs,
                                                        float poolingToFollow) {
  if (filterSize>1) {
    layers.push_back(new ConvolutionalTriangularLayer(filterSize, filterStride, dimension, nOutputFeatures, minActiveInputs));
    nOutputFeatures*=triangleSize(filterSize,dimension);
  }
  addLearntLayer(nFeatures,activationFn,dropout,powf(filterSize*1.0/filterStride/poolingToFollow,2));
}
void SparseConvNetCUDA::addTriangularLeNetLayerMP(int nFeatures, int filterSize, int filterStride, int poolSize, int poolStride, ActivationFunction activationFn, float dropout, int minActiveInputs) {
  addTriangularConvolutionalLayer(nFeatures,filterSize,filterStride,activationFn,dropout,poolSize,minActiveInputs);
  if (poolSize>1) {
    layers.push_back(new MaxPoolingTriangularLayer(poolSize, poolStride,dimension));
  }
}

void SparseConvNetCUDA::addTerminalPoolingLayer(int poolSize, int S) {
  layers.push_back(new TerminalPoolingLayer(poolSize,S));
}

void SparseConvNetCUDA::addSoftmaxLayer() {
  addLearntLayer(nClasses, SOFTMAX,0.0f,10000);
  inputSpatialSize=1;
  for (int i=layers.size()-1;i>=0;i--) {
    inputSpatialSize=layers[i]->calculateInputSpatialSize(inputSpatialSize);
  }
  std::cout <<"Spatially sparse CNN: input size " << inputSpatialSize;
  for (int i=1;i<dimension;++i)
    std::cout <<"x"<<inputSpatialSize;
  std::cout << std::endl;
}
void SparseConvNetCUDA::addIndexLearnerLayer() {
  layers.push_back(new IndexLearnerLayer(nOutputFeatures, nClasses));
  std::cout << "Index Learner " << nOutputFeatures << "-> " << nClasses<<std::endl;
  nOutputFeatures=nClasses; // "nClasses"=trainingSet.pictures.size()
  inputSpatialSize=1;
  for (int i=layers.size()-1;i>=0;i--) {
    inputSpatialSize=layers[i]->calculateInputSpatialSize(inputSpatialSize);
  }
  std::cout <<"Spatially sparse CNN: input size " << inputSpatialSize;
  for (int i=1;i<dimension;++i)
    std::cout <<"x"<<inputSpatialSize;
  std::cout << std::endl;
}
void SparseConvNetCUDA::processBatch(SpatiallySparseBatch& batch, float learningRate, float momentum, std::ofstream& f, std::ofstream& g) {
  for (int i=0;i<layers.size();i++) {
    layers[i]->sub.reset();
    layers[i]->forwards(batch,batch.interfaces[i],batch.interfaces[i+1]);
    if (batch.type==RESCALEBATCH and i<layers.size()-1) {
      std::cout << i << ":" << batch.interfaces[i].sub->features.size()*sizeof(float)/(1<<20) << "MB ";
      layers[i]->scaleWeights(batch.interfaces[i],batch.interfaces[i+1]);
    }
  }
  SoftmaxClassifier(batch.interfaces.back(),batch,nTop);
  if (batch.type==TRAINBATCH)
    for (int i=layers.size()-1; i>=0; i--) {
      layers[i]->backwards(batch,batch.interfaces[i],batch.interfaces[i+1],learningRate,momentum);
    }
  if (f)
    for (int j=0;j<batch.predictions.size();j++) {
      for (int k=0;k<batch.predictions[j].size();k++) {
        if (k>0) f << " ";
        f << batch.predictions[j][k];
      }
      f << std::endl;
    }
  if (g)
    for (int j=0;j<batch.predictions.size();j++) {
      for (int k=0;k<batch.probabilities[j].size();k++) {
        if (k>0) g << " ";
        g << batch.probabilities[j][k];
      }
      g << std::endl;
    }
}
float SparseConvNetCUDA::processDataset(SpatiallySparseDataset &dataset, int batchSize, float learningRate, float momentum) {
  float errorRate=0, nll=0;
  multiplyAddCount=0;
  auto start=std::chrono::system_clock::now();
  std::ofstream f,g;
  BatchProducer bp(*this,dataset,inputSpatialSize,batchSize);
  if (dataset.type==UNLABELEDBATCH) {
    f.open("unlabelledData.predictions");
    g.open("unlabelledData.probabilities");
  }
  while(SpatiallySparseBatch* batch=bp.nextBatch()) {
    processBatch(*batch,learningRate,momentum,f,g);
    errorRate+=batch->mistakes*1.0/dataset.pictures.size();
    nll+=batch->negativeLogLikelihood*1.0/dataset.pictures.size();
  }
  auto end=std::chrono::system_clock::now();
  auto diff = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();

  std::cout << dataset.name
            << " Mistakes:"
            << 100.0*errorRate
            << "% NLL:"
            << nll
            << " MegaMultiplyAdds/sample:"
            << roundf(multiplyAddCount/dataset.pictures.size()/1000000)
            << " time:"
            << diff/1000000000L
            << "s GigaMultiplyAdds/s:"
            << roundf(multiplyAddCount/diff)
            << " rate:" << roundf(dataset.pictures.size()*1000000000.0f/diff) << "/s"
            << std::endl;
  return nll;
}
void SparseConvNetCUDA::processDatasetRepeatTest(SpatiallySparseDataset &dataset, int batchSize, int nReps, std::string predictionsFilename,std::string header,std::string confusionMatrixFilename) {
  multiplyAddCount=0;
  auto start=std::chrono::system_clock::now();
  std::vector<std::vector<int  > > votes(dataset.pictures.size());
  std::vector<std::vector<float> > probs(dataset.pictures.size());
  for (int i=0;i<dataset.pictures.size();++i) {
    votes[i].resize(dataset.nClasses);
    probs[i].resize(dataset.nClasses);
  }
  for (int rep=1;rep<=nReps;++rep) {
    BatchProducer bp(*this,dataset,inputSpatialSize,batchSize);
    while(SpatiallySparseBatch* batch=bp.nextBatch()) {
      std::ofstream f,g;
      processBatch(*batch,0,0,f,g);
      for (int i=0;i<batch->batchSize;++i) {
        int ii=batch->sampleNumbers[i];
        votes[ii][batch->predictions[i][0]]++;
        for (int j=0;j<dataset.nClasses;++j)
          probs[ii][j]+=batch->probabilities[i][j];
      }
    }
    int errors=dataset.pictures.size();
    float nll=0;
    for (int i=0;i<dataset.pictures.size();++i) {
      std::vector<int> predictions=vectorTopIndices(probs[i],nTop);
      for (int j=0;j<nTop;j++)
        if (predictions[j]==dataset.pictures[i]->label)
          errors--;
      nll-=log(max(probs[i][dataset.pictures[i]->label]/rep,1.0e-15));
    }

    if (!predictionsFilename.empty()) {
      std::cout << predictionsFilename << std::endl;
      std::ofstream f(predictionsFilename.c_str());
      f << header << std::endl;
      for (int i=0;i<dataset.pictures.size();++i) {
        f << dataset.pictures[i]->identify();
        if (dataset.type!=UNLABELEDBATCH)
          f<<","<<dataset.pictures[i]->label;
        for (int j=0;j<dataset.nClasses;++j)
          f <<"," << probs[i][j]/rep;
        f <<std::endl;
      }
    }
    if (!confusionMatrixFilename.empty()) {
      std::vector<float> cm(dataset.nClasses*dataset.nClasses);
      for (int i=0;i<dataset.pictures.size();++i)
        for (int j=0;j<dataset.nClasses;++j)
          cm[dataset.pictures[i]->label*dataset.nClasses+j]+= probs[i][j]/rep;
      std::ofstream f(confusionMatrixFilename.c_str());
      for (int i=0;i<dataset.nClasses;++i) {
        for (int j=0;j<dataset.nClasses;++j) {
          f << cm[i*dataset.nClasses+j] <<" ";
        }
        f<< std::endl;
      }
    }
    auto end=std::chrono::system_clock::now();
    auto diff = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
    std::cout << dataset.name
              << " rep " << rep <<"/"<<nReps
              << " Mistakes: " << 100.0*errors/dataset.pictures.size()
              << "% NLL " << nll/dataset.pictures.size()
              << " MegaMultiplyAdds/sample:"
              << roundf(multiplyAddCount/dataset.pictures.size()/1000000)
              << " time:"
              << diff/1000000000L
              << "s GigaMultiplyAdds/s:"
              << roundf(multiplyAddCount/diff)
              << " rate:" << roundf(dataset.pictures.size()*1000000000.0f/diff) << "/s"
              << std::endl;
  }
}
void SparseConvNetCUDA::loadWeights(std::string baseName, int epoch, int firstNlayers) {
  std::string filename=std::string(baseName)+std::string("_epoch-")+std::to_string(epoch)+std::string(".cnn");
  std::ifstream f;
  f.open(filename.c_str(),std::ios::out | std::ios::binary);
  if (f) {
    std::cout << "Loading network parameters from " << filename << std::endl;
  } else {
    std::cout <<"Cannot find " << filename << std::endl;
    exit(EXIT_FAILURE);
  }
  for (int i=0;i<min((int)layers.size(),firstNlayers);i++)
    layers[i]->loadWeightsFromStream(f);
  f.close();
}
void SparseConvNetCUDA::saveWeights(std::string baseName, int epoch)  {
  std::string filename=std::string(baseName)+std::string("_epoch-")+std::to_string(epoch)+std::string(".cnn");
  std::ofstream f;
  f.open(filename.c_str(),std::ios::binary);
  if (f) {
    for (int i=0;i<layers.size();i++)
      layers[i]->putWeightsToStream(f);
    f.close();
  } else {
    std::cout <<"Cannot write " << filename << std::endl;
    exit(EXIT_FAILURE);
  }
}
void SparseConvNetCUDA::processIndexLearnerBatch(SpatiallySparseBatch& batch, float learningRate, float momentum, std::ofstream& f) {
  int n=layers.size();
  for (int i=0;i<n-1;i++)   //Stop 1 early (unless it is a training batch)
    layers[i]->forwards(batch,batch.interfaces[i],batch.interfaces[i+1]);
  if (f.is_open()) {
    assert(batch.interfaces[n-1].nFeatures==batch.interfaces[n-1].featuresPresent.size());
    for (int i=0;i<batch.batchSize;i++) {
      f << batch.sampleNumbers[i] << " " << batch.labels.hVector()[i];
      for (int j=0;j<batch.interfaces[n-1].nFeatures;j++)
        f << " " << batch.interfaces[n-1].sub->features.hVector()[i*batch.interfaces[n-1].nFeatures+j];
      f << std::endl;
    }
  }
  if (batch.type==TRAINBATCH) {
    dynamic_cast<IndexLearnerLayer*>(layers[n-1])->indexLearnerIndices=batch.sampleNumbers;
    layers[n-1]->forwards(batch,batch.interfaces[n-1],batch.interfaces[n]);
    IndexLearner(batch.interfaces[n],batch,nTop);
    for (int i=n-1;i>=0;i--)
      layers[i]->backwards(batch,batch.interfaces[i],batch.interfaces[i+1],learningRate,momentum);
  }
}
float SparseConvNetCUDA::processIndexLearnerDataset(SpatiallySparseDataset &dataset, int batchSize, float learningRate, float momentum) {
  float errorRate=0, nll=0;
  auto start=std::chrono::system_clock::now();
  multiplyAddCount=0;
  std::ofstream f;
  BatchProducer bp(*this,dataset,inputSpatialSize,batchSize);
  if (dataset.type!=TRAINBATCH) {
    std::string filename=dataset.name+".features";
    f.open(filename.c_str());
  }
  while(SpatiallySparseBatch* batch=bp.nextBatch()) {
    processIndexLearnerBatch(*batch,learningRate,momentum,f);
    errorRate+=batch->mistakes*1.0/dataset.pictures.size();
    nll+=batch->negativeLogLikelihood*1.0/dataset.pictures.size();
  }
  auto end=std::chrono::system_clock::now();
  auto diff = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
  if (dataset.type==TRAINBATCH)
    std::cout << dataset.name
              << " Mistakes:"
              << 100*errorRate
              << "% NLL:"
              << nll
              << " MegaMultiplyAdds/sample:"
              << roundf(multiplyAddCount/dataset.pictures.size()/1000000)
              << " time:"
              << diff/1000000000L
              << "s GigaMultiplyAdds/s:"
              << roundf(multiplyAddCount/diff)
              << " rate:" << roundf(dataset.pictures.size()*1000000000.0f/diff) << "/s"
              << std::endl;
  return nll;
}
void SparseConvNetCUDA::processBatchDumpTopLevelFeaturess(SpatiallySparseBatch& batch, std::ofstream& f) { //editted: test
  int n=layers.size();
  for (int i=0;i<layers.size()-1;i++) {
    layers[i]->forwards(batch,batch.interfaces[i],batch.interfaces[i+1]);
  }
  assert(batch.interfaces[n-1].nFeatures==batch.interfaces[n-1].featuresPresent.size());
  for (int i=0;i<batch.batchSize;i++) {
    f << batch.sampleNumbers[i] << " " << batch.labels.hVector()[i];
    for (int j=0;j<batch.interfaces[n-1].nFeatures;j++)
      f << " " << batch.interfaces[n-1].sub->features.hVector()[i*batch.interfaces[n-1].nFeatures+j];
    f << std::endl;
  }
}
void SparseConvNetCUDA::processDatasetDumpTopLevelFeatures(SpatiallySparseDataset &dataset, int batchSize, int reps) {
  std::ofstream f;
  assert(dataset.type!=TRAINBATCH);
  std::string filename=dataset.name+".features";
  f.open(filename.c_str());
  for (int i=0;i<reps;i++) {
    BatchProducer bp(*this,dataset,inputSpatialSize,batchSize);
    while(SpatiallySparseBatch* batch=bp.nextBatch()) {
      processBatchDumpTopLevelFeaturess(*batch,f);
    }
  }
}


void SparseConvNetCUDA::calculateInputRegularizingConstants(SpatiallySparseDataset dataset) { //make copy of the dataset
  inputNormalizingConstants.resize(0); //Make sure input features rescaling is turned off.
  std::cout << "Using " << std::min(10000,(int)dataset.pictures.size()) << " out of " << dataset.pictures.size() << " training samples to calculate regularizing constants." << std::endl;
  dataset.pictures.resize(10000);
  dataset.type=TESTBATCH;  //pretend it is a test batch to turn off dropout and training data augmentation
  BatchProducer bp(*this,dataset,inputSpatialSize,100);
  std::vector<float> c(nInputFeatures,0);
  while(SpatiallySparseBatch* batch=bp.nextBatch()) {
    {
      std::vector<float> &features=batch->interfaces[0].sub->features.hVector();
      for (int i=0; i<features.size(); ++i)
        c[i%nInputFeatures]=std::max(c[i%nInputFeatures],std::fabs(features[i]));
    }
  }
  for (int i=0;i<nInputFeatures;++i) {
    inputNormalizingConstants.push_back(c[i]>0?1.0f/c[i]:0);
    std::cout << inputNormalizingConstants.back() << " ";
  }
  std::cout << std::endl;
}
