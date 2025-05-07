"""
Static embedding data processor with TPU optimization.

This module handles preprocessing of inputs for static embedding models
with a focus on TPU compatibility.
"""

import os
import logging
from typing import Dict, List, Optional, Any, Tuple, Union, Callable
import numpy as np
import torch
from tqdm import tqdm

# Import from package
from ..utils.processing import (
    hash_config, is_cache_valid, save_to_cache, load_from_cache, 
    clean_text, process_in_parallel, pad_sequences
)
from ..utils.data_io import load_dataset
from ..tasks import create_task_generator
from ..types import StaticInput, StaticTarget

# Setup logger
logger = logging.getLogger('processors.static')

class VocabularyProvider:
    """Base class for vocabulary providers."""
    
    def get_vocabulary(self, config: Dict) -> Dict[str, int]:
        """Get word-to-index vocabulary based on configuration."""
        raise NotImplementedError("Subclasses must implement get_vocabulary")

class DefaultVocabularyProvider(VocabularyProvider):
    """Default implementation of vocabulary provider."""
    
    def get_vocabulary(self, config: Dict) -> Dict[str, int]:
        """
        Get word-to-index vocabulary based on configuration.
        
        Args:
            config: Vocabulary configuration
            
        Returns:
            Dictionary mapping words to indices
        """
        vocab_size = config.get('vocab_size', 20000)
        model_type = config.get('model_type', 'unigram')
        
        try:
            # Try to use SentencePiece if available
            try:
                import sentencepiece as spm
                logger.info(f"Using SentencePiece for vocabulary generation")
                has_sentencepiece = True
            except ImportError:
                logger.warning("SentencePiece not available, falling back to basic tokenization")
                has_sentencepiece = False
            
            if has_sentencepiece and os.path.exists(config.get('model', '')):
                # Load existing model
                sp = spm.SentencePieceProcessor()
                sp.load(config.get('model'))
                
                # Create vocabulary
                vocab = {}
                for i in range(sp.get_piece_size()):
                    piece = sp.id_to_piece(i)
                    vocab[piece] = i
                
                logger.info(f"Loaded SentencePiece vocabulary with {len(vocab)} entries")
                return vocab
            else:
                # Create basic vocabulary from special tokens
                special_tokens = config.get('special_tokens', {})
                vocab = {token: i for i, token in enumerate(special_tokens.values())}
                
                # We'll expand this later when processing text
                logger.info(f"Created initial vocabulary with {len(vocab)} special tokens")
                return vocab
                
        except Exception as e:
            logger.error(f"Failed to initialize vocabulary: {e}")
            raise

class CacheManager:
    """Base class for cache managers."""
    
    def is_cached(self, cache_path: str) -> bool:
        """Check if cached data exists and is valid."""
        raise NotImplementedError("Subclasses must implement is_cached")
    
    def load(self, cache_path: str) -> Any:
        """Load data from cache."""
        raise NotImplementedError("Subclasses must implement load")
    
    def save(self, data: Any, cache_path: str) -> None:
        """Save data to cache."""
        raise NotImplementedError("Subclasses must implement save")

class DefaultCacheManager(CacheManager):
    """Default implementation of cache manager."""
    
    def is_cached(self, cache_path: str) -> bool:
        """
        Check if cached data exists and is valid.
        
        Args:
            cache_path: Path to cache file
            
        Returns:
            True if cache is valid, False otherwise
        """
        return is_cache_valid(cache_path)
    
    def load(self, cache_path: str) -> Any:
        """
        Load data from cache.
        
        Args:
            cache_path: Path to cache file
            
        Returns:
            Cached data
        """
        return load_from_cache(cache_path)
    
    def save(self, data: Any, cache_path: str) -> None:
        """
        Save data to cache.
        
        Args:
            data: Data to cache
            cache_path: Path to cache file
        """
        save_to_cache(data, cache_path)

class StaticProcessor:
    """Processor for static embedding model data with dependency injection."""
    
    def __init__(
        self,
        vocabulary_provider: Optional[VocabularyProvider] = None,
        cache_manager: Optional[CacheManager] = None
    ):
        """
        Initialize the static processor.
        
        Args:
            vocabulary_provider: Provider for vocabularies
            cache_manager: Manager for caching
        """
        self.vocabulary_provider = vocabulary_provider or DefaultVocabularyProvider()
        self.cache_manager = cache_manager or DefaultCacheManager()
    
    def tokenize_text(
        self, 
        text: str, 
        vocabulary: Dict[str, int],
        context_size: int,
        unk_token: str = '<unk>',
        split_fn: Optional[Callable] = None
    ) -> List[int]:
        """
        Tokenize text into word indices for static embeddings.
        
        Args:
            text: Text to tokenize
            vocabulary: Word-to-index vocabulary
            context_size: Size of context window
            unk_token: Token to use for unknown words
            split_fn: Custom splitting function
            
        Returns:
            List of word indices
        """
        if split_fn is None:
            # Default to simple whitespace splitting
            words = text.strip().split()
        else:
            words = split_fn(text)
        
        # Convert words to indices
        indices = []
        for word in words:
            if word in vocabulary:
                indices.append(vocabulary[word])
            else:
                indices.append(vocabulary.get(unk_token, 0))
        
        return indices
    
    def create_cbow_examples(
        self,
        word_indices: List[int],
        context_size: int,
        vocabulary_size: int,
        pad_token_id: int
    ) -> List[Tuple[np.ndarray, np.ndarray, np.ndarray]]:
        """
        Create CBOW (Continuous Bag of Words) examples.
        
        Args:
            word_indices: List of word indices
            context_size: Size of context window (one-sided)
            vocabulary_size: Size of vocabulary
            pad_token_id: ID of padding token
            
        Returns:
            List of (center_words, context_words, context_mask) tuples
        """
        examples = []
        
        for i in range(len(word_indices)):
            # Center word is target
            center_word = np.array([word_indices[i]], dtype=np.int64)
            
            # Context words are inputs
            context_words = []
            for j in range(i - context_size, i + context_size + 1):
                if j == i:
                    continue  # Skip center word
                
                if 0 <= j < len(word_indices):
                    context_words.append(word_indices[j])
                else:
                    context_words.append(pad_token_id)
            
            # Convert to arrays and create mask
            context_array = np.array(context_words, dtype=np.int64)
            context_mask = np.array(
                [1 if w != pad_token_id else 0 for w in context_words],
                dtype=np.int32
            )
            
            examples.append((center_word, context_array, context_mask))
        
        return examples
    
    def create_skipgram_examples(
        self,
        word_indices: List[int],
        context_size: int,
        vocabulary_size: int,
        pad_token_id: int
    ) -> List[Tuple[np.ndarray, np.ndarray, np.ndarray]]:
        """
        Create Skip-gram examples.
        
        Args:
            word_indices: List of word indices
            context_size: Size of context window (one-sided)
            vocabulary_size: Size of vocabulary
            pad_token_id: ID of padding token
            
        Returns:
            List of (center_words, context_words, context_mask) tuples
        """
        examples = []
        
        for i in range(len(word_indices)):
            center_word = word_indices[i]
            
            # For each position in the context window
            for j in range(i - context_size, i + context_size + 1):
                if j == i:
                    continue  # Skip center word
                
                if 0 <= j < len(word_indices):
                    # Center word is input, context word is target
                    center_array = np.array([center_word], dtype=np.int64)
                    context_array = np.array([word_indices[j]], dtype=np.int64)
                    context_mask = np.array([1], dtype=np.int32)
                    
                    examples.append((center_array, context_array, context_mask))
        
        return examples
    
    def process_example(self, item: Dict[str, Any]) -> List[Tuple[StaticInput, StaticTarget]]:
        """
        Process a single example to create static embedding inputs and targets.
        
        Args:
            item: Dictionary with example data
            
        Returns:
            List of (StaticInput, StaticTarget) tuples
        """
        text = item['text']
        label = item.get('label')
        vocabulary = item['vocabulary']
        unk_token = item.get('unk_token', '<unk>')
        pad_token = item.get('pad_token', '<pad>')
        dataset_config = item['dataset_config']
        static_config = item['static_config']
        
        # Get configuration parameters
        context_size = static_config.get('word2vec', {}).get('window_size', 2)
        context_type = static_config.get('word2vec', {}).get('context_type', 'cbow')
        
        # Clean text
        preprocessing_config = dataset_config.get('preprocessing', {})
        clean_text_str = clean_text(text, preprocessing_config)
        
        # Tokenize text
        word_indices = self.tokenize_text(
            clean_text_str, 
            vocabulary,
            context_size,
            unk_token
        )
        
        # Skip if no valid tokens
        if not word_indices:
            return []
        
        # Get token IDs
        pad_token_id = vocabulary.get(pad_token, 0)
        vocabulary_size = len(vocabulary)
        
        # Create examples based on context type
        if context_type == 'cbow':
            examples = self.create_cbow_examples(
                word_indices, context_size, vocabulary_size, pad_token_id
            )
        else:  # skipgram
            examples = self.create_skipgram_examples(
                word_indices, context_size, vocabulary_size, pad_token_id
            )
        
        # Create StaticInput and StaticTarget objects
        results = []
        for center_words, context_words, context_mask in examples:
            # Create input
            static_input = StaticInput(
                center_words=center_words,
                context_words=context_words,
                context_mask=context_mask,
                metadata={
                    'original_text': clean_text_str,
                    'original_length': len(clean_text_str.split())
                }
            )
            
            # Create target with one-hot encoded vectors
            target_values = np.zeros(vocabulary_size, dtype=np.float32)
            target_values[center_words[0]] = 1.0
            
            static_target = StaticTarget(
                target_values=target_values,
                target_mask=np.array([1], dtype=np.int32)
            )
            
            # Add original label if available
            if label is not None:
                static_target.metadata = {'original_label': label}
            
            results.append((static_input, static_target))
        
        return results
    
    def process_dataset(
        self,
        dataset_name: str,
        config: Dict,
        output_dir: str,
        transformer_data: Optional[Dict] = None,
        cache_dir: Optional[str] = None,
        force: bool = False,
        n_processes: Optional[int] = None
    ) -> Dict:
        """
        Preprocess a dataset for static embedding models.
        
        Args:
            dataset_name: Name of the dataset to process
            config: Configuration dictionary
            output_dir: Directory to save processed data
            transformer_data: Optional transformer data for alignment
            cache_dir: Directory for caching
            force: Whether to force reprocessing
            n_processes: Number of processes for parallel processing
            
        Returns:
            Dictionary with preprocessing results
        """
        # Ensure output directory exists
        os.makedirs(output_dir, exist_ok=True)
        
        # Create dataset-specific output directory
        dataset_dir = os.path.join(output_dir, dataset_name)
        if os.path.exists(dataset_dir) and not force:
            logger.info(f"Processed dataset already exists at {dataset_dir}. Use --force to overwrite.")
            
            # Try to load existing data
            try:
                inputs_path = os.path.join(dataset_dir, "inputs.pt")
                targets_path = os.path.join(dataset_dir, "targets.pt")
                
                static_inputs = torch.load(inputs_path)
                static_targets = torch.load(targets_path)
                
                # Load vocabulary
                vocab_path = os.path.join(dataset_dir, "vocabulary.pt")
                vocabulary = torch.load(vocab_path)
                
                # Return data
                return {
                    'vocabulary': vocabulary,
                    'static_inputs': static_inputs,
                    'static_targets': static_targets
                }
            except Exception as e:
                logger.warning(f"Failed to load existing data: {e}")
                logger.info("Will reprocess dataset.")
        
        # Check cache if enabled
        if cache_dir:
            os.makedirs(cache_dir, exist_ok=True)
            config_hash = hash_config(config['datasets'][dataset_name])
            cache_path = os.path.join(cache_dir, f"{dataset_name}_static_{config_hash}.pt")
            
            if self.cache_manager.is_cached(cache_path) and not force:
                logger.info(f"Loading cached data from {cache_path}")
                try:
                    result = self.cache_manager.load(cache_path)
                    
                    # Save to output directory
                    os.makedirs(dataset_dir, exist_ok=True)
                    torch.save(result['static_inputs'], os.path.join(dataset_dir, "inputs.pt"))
                    torch.save(result['static_targets'], os.path.join(dataset_dir, "targets.pt"))
                    torch.save(result['vocabulary'], os.path.join(dataset_dir, "vocabulary.pt"))
                    
                    # Generate task labels
                    self._generate_task_labels(
                        dataset_name=dataset_name,
                        inputs=result['static_inputs'],
                        config=config,
                        cache_dir=cache_dir,
                        output_dir=dataset_dir
                    )
                    
                    return result
                except Exception as e:
                    logger.warning(f"Failed to load cache: {e}")
        
        # Load dataset configuration
        dataset_config = config['datasets'][dataset_name]
        text_column = dataset_config['text_column']
        label_column = dataset_config['label_column']
        
        # Get static configuration
        static_config = config['tokenizers']['static']
        
        # Initialize vocabulary
        vocabulary = self.vocabulary_provider.get_vocabulary(static_config)
        
        # Get special tokens
        special_tokens = static_config.get('special_tokens', {})
        pad_token = special_tokens.get('pad', '<pad>')
        unk_token = special_tokens.get('unk', '<unk>')
        
        # Load dataset
        raw_dir = "/app/mount/src/datasets/raw"
        raw_dataset = load_dataset(dataset_name, os.path.dirname(raw_dir))
        
        # Get texts and labels
        texts = raw_dataset['unsplit'][text_column]
        labels = None
        if label_column and label_column in raw_dataset['unsplit'].column_names:
            labels = raw_dataset['unsplit'][label_column]
        
        # Prepare items for parallel processing
        items = []
        for i in range(len(texts)):
            item = {
                'vocabulary': vocabulary,
                'unk_token': unk_token,
                'pad_token': pad_token,
                'text': texts[i],
                'dataset_config': dataset_config,
                'static_config': static_config
            }
            if labels is not None:
                item['label'] = labels[i]
            items.append(item)
        
        # Process examples in parallel
        logger.info(f"Processing {len(items)} examples for {dataset_name}")
        
        # Set default number of processes
        if n_processes is None:
            n_processes = config.get('alignment', {}).get('parallel', {}).get('n_processes', 4)
        
        # Error handler
        def error_handler(errors):
            for item, error in errors:
                logger.error(f"Failed to process example: {error}")
        
        # Process in parallel
        parallel_config = {
            'n_processes': n_processes,
            'chunk_size': config.get('alignment', {}).get('parallel', {}).get('chunk_size', 10),
            'desc': f"Processing {dataset_name}"
        }
        
        all_results = process_in_parallel(
            process_fn=self.process_example,
            items=items,
            config=parallel_config,
            error_handler=error_handler
        )
        
        # Flatten results
        flat_results = []
        for result_list in all_results:
            flat_results.extend(result_list)
        
        # Unpack results
        inputs, targets = zip(*flat_results) if flat_results else ([], [])
        
        # Save processed data
        logger.info(f"Saving processed data to {dataset_dir}")
        os.makedirs(dataset_dir, exist_ok=True)
        
        torch.save(inputs, os.path.join(dataset_dir, "inputs.pt"))
        torch.save(targets, os.path.join(dataset_dir, "targets.pt"))
        torch.save(vocabulary, os.path.join(dataset_dir, "vocabulary.pt"))
        
        # Prepare result dictionary
        result = {
            'vocabulary': vocabulary,
            'static_inputs': inputs,
            'static_targets': targets
        }
        
        # Cache result if enabled
        if cache_dir:
            logger.info(f"Caching processed data to {cache_path}")
            self.cache_manager.save(result, cache_path)
        
        # Generate task labels
        self._generate_task_labels(
            dataset_name=dataset_name,
            inputs=inputs,
            config=config,
            cache_dir=cache_dir,
            output_dir=dataset_dir
        )
        
        logger.info(f"Dataset {dataset_name} processed successfully with {len(inputs)} examples")
        return result
    
    def _generate_task_labels(
        self,
        dataset_name: str,
        inputs: List[StaticInput],
        config: Dict,
        output_dir: str,
        cache_dir: Optional[str] = None
    ) -> None:
        """
        Generate task-specific labels for the dataset.
        
        Args:
            dataset_name: Name of the dataset
            inputs: List of static inputs
            config: Configuration dictionary
            output_dir: Output directory for the dataset
            cache_dir: Directory for caching
        """
        logger.info(f"Generating task labels for static dataset: {dataset_name}")
        
        # Load targets
        targets_path = os.path.join(output_dir, "targets.pt")
        targets = torch.load(targets_path)
        
        # Load vocabulary
        vocab_path = os.path.join(output_dir, "vocabulary.pt")
        vocabulary = torch.load(vocab_path)
        
        # Get enabled tasks
        dataset_config = config['datasets'][dataset_name]
        enabled_tasks = dataset_config.get('enabled_tasks', [])
        
        if not enabled_tasks:
            logger.info(f"No tasks enabled for dataset {dataset_name}")
            return
        
        # Generate labels for each task
        all_task_labels = {}
        
        for task_name in enabled_tasks:
            # Get task-specific configuration
            task_config = {}
            
            # First get default configuration for this task type
            task_defaults = config.get('tasks', {}).get(task_name, {}).get('defaults', {})
            task_config.update(task_defaults)
            
            # Then apply dataset-specific overrides
            task_overrides = dataset_config.get('task_overrides', {}).get(task_name, {})
            task_config.update(task_overrides)
            
            # Create task generator
            generator = create_task_generator(task_name, task_config)
            
            if generator and generator.supports_model_type('static'):
                # Generate labels
                logger.info(f"Generating {task_name} labels for {dataset_name}")
                task_labels = generator.generate_labels(inputs, None)  # No tokenizer for static model
                all_task_labels[task_name] = task_labels
            else:
                logger.info(f"Skipping {task_name} (not supported)")
        
        # Update targets with generated task labels
        for task_name, task_labels in all_task_labels.items():
            logger.info(f"Adding {task_name} labels to {len(targets)} targets")
            
            for i, (target, task_label) in enumerate(zip(targets, task_labels)):
                if task_label is not None:
                    target.task_labels[task_name] = task_label
        
        # Save updated targets
        torch.save(targets, targets_path)
        logger.info(f"Updated targets saved to {targets_path}") 