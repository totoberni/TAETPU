"""
Data preprocessing for static embedding models with token alignment.

This script handles tokenization, alignment, and preparation of inputs
for static embedding models, leveraging transformer data where available.
"""

import os
import logging
from typing import Dict, List, Optional, Any, Tuple
import numpy as np
import torch
import sentencepiece as spm
from tqdm import tqdm

# Import custom modules
from data_types import StaticInput, StaticTarget
import processing_utils as utils

# Setup logger
logger = utils.setup_logger('process_static')

def train_sentencepiece_model(texts: List[str], tokenizer_config: Dict, output_dir: str) -> str:
    """Train a SentencePiece model on the dataset texts."""
    logger.info("Training SentencePiece model")
    os.makedirs(output_dir, exist_ok=True)
    
    # Create corpus file
    temp_corpus_path = os.path.join(output_dir, 'temp_corpus.txt')
    with open(temp_corpus_path, 'w', encoding='utf-8') as f:
        for text in texts:
            f.write(f"{text}\n")
    
    # Set model parameters
    model_prefix = os.path.join(output_dir, tokenizer_config.get('model', 'spm_model'))
    vocab_size = tokenizer_config.get('vocab_size', 20000)
    character_coverage = tokenizer_config.get('character_coverage', 0.9995)
    model_type = tokenizer_config.get('model_type', 'unigram')
    special_tokens = tokenizer_config.get('special_tokens', {})
    
    # Train model
    spm.SentencePieceTrainer.train(
        input=temp_corpus_path,
        model_prefix=model_prefix,
        vocab_size=vocab_size,
        character_coverage=character_coverage,
        model_type=model_type,
        pad_id=0,
        unk_id=1,
        bos_id=2,
        eos_id=3,
        unk_surface=special_tokens.get('unk', '<unk>'),
        pad_piece=special_tokens.get('pad', '<pad>'),
        bos_piece=special_tokens.get('cls', '<cls>'),
        eos_piece=special_tokens.get('sep', '<sep>')
    )
    
    os.remove(temp_corpus_path)
    return f"{model_prefix}.model"

def load_sentencepiece_model(model_path: str) -> spm.SentencePieceProcessor:
    """Load SentencePiece model."""
    logger.info(f"Loading SentencePiece model from {model_path}")
    sp_model = spm.SentencePieceProcessor()
    sp_model.load(model_path)
    return sp_model

def tokenize_text_sp(texts: List[str], sp_model: spm.SentencePieceProcessor, max_length: int) -> Dict[str, Any]:
    """Tokenize texts using SentencePiece model."""
    logger.info(f"Tokenizing {len(texts)} texts with SentencePiece")
    
    # Get special token IDs
    pad_id = sp_model.piece_to_id('<pad>')
    cls_id = sp_model.piece_to_id('<cls>')
    sep_id = sp_model.piece_to_id('<sep>')
    
    input_ids = []
    attention_masks = []
    sp_tokens_list = []
    
    for text in texts:
        # Encode text
        tokens = sp_model.encode_as_ids(text)
        tokens_str = sp_model.encode_as_pieces(text)
        
        # Add special tokens
        tokens = [cls_id] + tokens + [sep_id]
        tokens_str = ['<cls>'] + tokens_str + ['<sep>']
        
        # Truncate if needed
        if len(tokens) > max_length:
            tokens = tokens[:max_length-1] + [sep_id]
            tokens_str = tokens_str[:max_length-1] + ['<sep>']
        
        # Create attention mask and pad
        mask = [1] * len(tokens)
        padding_length = max_length - len(tokens)
        
        tokens.extend([pad_id] * padding_length)
        mask.extend([0] * padding_length)
        tokens_str.extend(['<pad>'] * padding_length)
        
        input_ids.append(tokens)
        attention_masks.append(mask)
        sp_tokens_list.append(tokens_str)
    
    return {
        'input_ids': np.array(input_ids, dtype=np.int32),
        'attention_mask': np.array(attention_masks, dtype=np.int32),
        'tokens': sp_tokens_list
    }

def generate_word2vec_inputs(
    token_ids: np.ndarray, 
    attention_mask: np.ndarray,
    config: Dict
) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Generate Word2Vec inputs from token sequences."""
    window_size = config.get('word2vec', {}).get('window_size', 2)
    
    # Filter valid positions
    valid_indices = [i for i in range(len(token_ids)) if attention_mask[i] == 1]
    
    center_words, context_words, context_masks = [], [], []
    
    for i in valid_indices:
        # Create context window
        context = []
        mask = []
        
        for j in range(max(0, i - window_size), min(len(token_ids), i + window_size + 1)):
            if i == j or attention_mask[j] == 0:
                continue
                
            context.append(token_ids[j])
            mask.append(1)
        
        # Only process if we have valid context
        if context:
            # Pad context to fixed size
            padding_length = 2 * window_size - len(context)
            context.extend([0] * padding_length)
            mask.extend([0] * padding_length)
            
            center_words.append(token_ids[i])
            context_words.append(context)
            context_masks.append(mask)
    
    # Handle empty case
    if not center_words:
        return (
            np.empty((0,), dtype=np.int32),
            np.empty((0, 2 * window_size), dtype=np.int32),
            np.empty((0, 2 * window_size), dtype=np.int32)
        )
    
    return (
        np.array(center_words, dtype=np.int32),
        np.array(context_words, dtype=np.int32),
        np.array(context_masks, dtype=np.int32)
    )

def process_static_example(item: Dict[str, Any]) -> Tuple[Optional[StaticInput], Optional[StaticTarget]]:
    """Process a single example to create static input and target."""
    sp_model = item['sp_model']
    text = item['text']
    label = item.get('label')
    transformer_tokens = item.get('transformer_tokens')
    transformer_word_ids = item.get('transformer_word_ids')
    dataset_config = item['dataset_config']
    tokenizer_config = item['tokenizer_config']
    max_length = dataset_config.get('max_length', 128)
    
    # Clean text using shared utility
    preprocessing_config = dataset_config.get('preprocessing', {})
    clean_text = utils.clean_text(text, preprocessing_config)
    
    # Skip empty texts
    if not clean_text:
        return None, None
    
    # Tokenize with SentencePiece
    sp_tokenized = tokenize_text_sp([clean_text], sp_model, max_length)
    
    # Generate Word2Vec inputs
    center, context, context_mask = generate_word2vec_inputs(
        sp_tokenized['input_ids'][0],
        sp_tokenized['attention_mask'][0],
        tokenizer_config
    )
    
    # Skip if no valid inputs
    if len(center) == 0:
        return None, None
    
    # Create alignment mapping if transformer tokens available
    alignment_map = None
    
    if transformer_tokens and transformer_word_ids:
        static_tokens = sp_tokenized['tokens'][0]
        
        # Create and verify alignment
        alignment_map = utils.create_token_alignment_map(
            transformer_tokens,
            static_tokens,
            transformer_word_ids,
            clean_text
        )
        
        alignment_quality = utils.verify_alignment(
            transformer_tokens,
            static_tokens,
            alignment_map,
            clean_text
        )
        
        alignment_threshold = item.get('alignment_threshold', 0.5)
        if alignment_quality < alignment_threshold:
            logger.warning(f"Low alignment quality: {alignment_quality:.2f}")
    
    # Create static input
    static_input = StaticInput(
        center_words=center,
        context_words=context,
        context_mask=context_mask,
        metadata={
            'original_text': clean_text,
            'original_length': len(clean_text.split()),
            'alignment_map': alignment_map
        }
    )
    
    # Create target
    static_target = StaticTarget(
        target_values=center,
        target_mask=np.ones_like(center)
    )
    
    # Add original label if available
    if label is not None:
        static_target.metadata = {'original_label': label}
    
    return static_input, static_target

def preprocess_static_dataset(
    dataset_name: str,
    data_config: Dict,
    output_dir: str,
    transformer_data: Optional[Dict] = None,
    sp_model: Optional[spm.SentencePieceProcessor] = None,
    cache_dir: str = None, 
    force: bool = False,
    use_cache: bool = True,
    n_processes: int = None
) -> None:
    """Preprocess dataset for static embedding models with token alignment."""
    # Ensure output directory exists (in tae_datasets volume, clean/static dir)
    os.makedirs(output_dir, exist_ok=True)
    
    # Set output path and check if exists
    output_path = os.path.join(output_dir, dataset_name)
    if os.path.exists(output_path) and not force:
        logger.info(f"Processed dataset already exists at {output_path}. Use --force to overwrite.")
        return
    
    # Check cache if enabled (in tae_cache volume)
    if cache_dir and use_cache:
        os.makedirs(cache_dir, exist_ok=True)
        config_hash = utils.hash_config(data_config['datasets'][dataset_name])
        cache_path = os.path.join(cache_dir, f"{dataset_name}_static_{config_hash}.pt")
        
        if utils.is_cache_valid(cache_path) and not force:
            logger.info(f"Loading cached data from {cache_path}")
            try:
                cached_data = utils.load_from_cache(cache_path)
                
                # Save to output directory as well (in tae_datasets volume)
                os.makedirs(output_path, exist_ok=True)
                
                # Save inputs and targets
                torch.save(cached_data['static_inputs'], os.path.join(output_path, "inputs.pt"))
                torch.save(cached_data['static_targets'], os.path.join(output_path, "targets.pt"))
                
                # Save SentencePiece model (to dataset-specific directory)
                sp_model_path = os.path.join(output_path, "sp_model.model")
                os.makedirs(os.path.dirname(sp_model_path), exist_ok=True)
                with open(sp_model_path, 'wb') as f:
                    f.write(cached_data['sp_model'].serialized_model_proto())
                
                logger.info(f"Loaded cached data for {dataset_name}")
                return
            except Exception as e:
                logger.warning(f"Failed to load cache: {e}")
    
    # Load dataset configuration
    dataset_config = data_config['datasets'][dataset_name]
    text_column = dataset_config['text_column']
    label_column = dataset_config['label_column']
    max_length = dataset_config.get('max_length', 128)
    
    # Get text data from transformer data or load and clean dataset
    clean_texts = []
    original_texts = []
    transformer_inputs = []
    transformer_tokens_list = []
    
    if transformer_data and 'clean_texts' in transformer_data:
        logger.info("Using pre-processed transformer data")
        clean_texts = transformer_data['clean_texts']
        transformer_inputs = transformer_data.get('transformer_inputs', [])
        
        # Get token strings for transformer tokenization
        if 'tokenizer' in transformer_data:
            tokenizer = transformer_data['tokenizer']
            for i, inp in enumerate(transformer_inputs):
                if hasattr(inp, 'input_ids') and hasattr(tokenizer, 'convert_ids_to_tokens'):
                    tokens = [tokenizer.convert_ids_to_tokens(int(id)) for id in inp.input_ids]
                    transformer_tokens_list.append(tokens)
    else:
        logger.info("Loading and cleaning dataset")
        # Load dataset from raw directory (tae_datasets volume)
        raw_dir = os.path.join("/app/mount/src/datasets/raw", dataset_name)
        raw_dataset = utils.load_dataset(dataset_name, os.path.dirname(raw_dir))
        original_texts = raw_dataset['unsplit'][text_column]
        
        # Clean texts
        preprocessing_config = dataset_config.get('preprocessing', {})
        for text in tqdm(original_texts, desc="Cleaning texts"):
            clean_texts.append(utils.clean_text(text, preprocessing_config))
    
    # Initialize SentencePiece model
    tokenizer_config = data_config['tokenizers']['static']
    
    if sp_model is None:
        # Try to load existing model or train new one (in tae_models volume)
        models_dir = "/app/mount/src/models/prep"
        os.makedirs(models_dir, exist_ok=True)
        sp_model_path = os.path.join(models_dir, f"{dataset_name}_{tokenizer_config.get('model', 'spm_model')}.model")
        
        if not os.path.exists(sp_model_path) or force:
            logger.info("Training new SentencePiece model")
            sp_model_path = train_sentencepiece_model(
                clean_texts, 
                tokenizer_config, 
                models_dir
            )
        
        sp_model = load_sentencepiece_model(sp_model_path)
    
    # Prepare items for parallel processing
    items = []
    
    for i in range(len(clean_texts)):
        item = {
            'sp_model': sp_model,
            'text': clean_texts[i],
            'dataset_config': dataset_config,
            'tokenizer_config': tokenizer_config,
            'alignment_threshold': data_config.get('alignment', {}).get('min_quality_threshold', 0.5)
        }
        
        # Add label if available
        if label_column and i < len(original_texts) and hasattr(original_texts, label_column):
            item['label'] = original_texts[label_column][i]
        
        # Add transformer data if available
        if i < len(transformer_tokens_list) and transformer_tokens_list:
            item['transformer_tokens'] = transformer_tokens_list[i]
            
            if i < len(transformer_inputs):
                item['transformer_word_ids'] = transformer_inputs[i].metadata.get('word_ids')
        
        items.append(item)
    
    # Process examples in parallel
    logger.info(f"Processing {len(items)} examples for {dataset_name}")
    
    if n_processes is None:
        n_processes = data_config.get('alignment', {}).get('parallel', {}).get('n_processes', 4)
    
    # Define error handler
    def error_handler(errors):
        for item, error in errors:
            logger.error(f"Failed to process example: {error}")
    
    # Process in parallel
    parallel_config = {
        'n_processes': n_processes,
        'chunk_size': data_config.get('alignment', {}).get('parallel', {}).get('chunk_size', 10),
        'desc': f"Processing {dataset_name}"
    }
    
    results = utils.process_in_parallel(
        process_fn=process_static_example,
        items=items,
        config=parallel_config,
        error_handler=error_handler
    )
    
    # Filter out None results and unpack
    filtered_results = [(inp, tgt) for inp, tgt in results if inp is not None and tgt is not None]
    
    if not filtered_results:
        logger.warning(f"No valid examples processed for {dataset_name}")
        return
    
    inputs, targets = zip(*filtered_results)
    
    # Save processed data (to tae_datasets volume, clean/static dir)
    logger.info(f"Saving processed data to {output_path}")
    os.makedirs(output_path, exist_ok=True)
    
    torch.save(inputs, os.path.join(output_path, "inputs.pt"))
    torch.save(targets, os.path.join(output_path, "targets.pt"))
    
    # Save SentencePiece model (to dataset-specific directory)
    sp_model_path = os.path.join(output_path, "sp_model.model")
    os.makedirs(os.path.dirname(sp_model_path), exist_ok=True)
    with open(sp_model_path, 'wb') as f:
        f.write(sp_model.serialized_model_proto())
    
    # Cache results if enabled (in tae_cache volume)
    if cache_dir and use_cache:
        cache_result = {
            'static_inputs': inputs,
            'static_targets': targets,
            'sp_model': sp_model,
            'clean_texts': clean_texts
        }
        logger.info(f"Caching processed data to {cache_path}")
        utils.save_to_cache(cache_result, cache_path)
    
    logger.info(f"Dataset {dataset_name} processed successfully with {len(inputs)} valid examples") 